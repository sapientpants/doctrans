defmodule Doctrans.Config.Inference do
  @moduledoc """
  Where inference actually happens, so the UI can only claim privacy it has.

  Doctrans is meant to run against a model server on the user's own machine, and
  the interface says so. That claim is a configuration fact, not a property of
  the app: `Doctrans.Config.OpenAI.base_url/0` (chat, vision, translation) and
  `Doctrans.Config.Embedding.base_url/0` (embeddings) are independently
  retargetable, and either one pointed off-box sends document text to a third
  party. Embeddings are not an exception — an embedding request carries the
  chunk text it is embedding — so a remote embedding host is document egress
  even when chat stays local.

  This module is the single source of truth for that question.
  `local?/0` guards the privacy copy; `destination_label/0` produces the one
  string that copy interpolates to say where documents go; `remote_hosts/0` and
  `endpoints/0` expose the structured detail behind it, because "chat is local
  but embeddings are not" is a state worth describing precisely.

  Locality is decided from the URL's host alone. A host that cannot be
  determined — a scheme-less value like `"llm:8000"`, which `URI.parse/1` reads
  as having no host — is classified `:unknown` and counts as **not** local:
  an unreadable endpoint must never buy a privacy guarantee. `:unknown` is kept
  distinct from `:remote` because it has no host to name, and the two are
  reconciled in `destination_label/0`, which always has something to show.

  The API key is deliberately absent from everything here. Its presence is not a
  locality signal — a server on loopback may well demand a bearer token — and it
  must never reach the UI. Endpoint URLs are equally credential-bearing, since
  an operator may write `http://user:secret@host` or a gateway URL that carries
  its key in the query, so every URL this module returns goes through
  `redact_url/1` first.
  """

  alias Doctrans.Config.Embedding
  alias Doctrans.Config.OpenAI

  @typedoc "An inference path, grouped by the endpoint setting that targets it."
  @type path :: :chat | :embedding

  @typedoc "`:unknown` is an unreadable endpoint, treated as not local."
  @type locality :: :local | :remote | :unknown

  @typedoc """
  One inference path's destination.

  `:host` is nil exactly when `:locality` is `:unknown`. `:base_url` is always a
  non-empty, credential-free string safe to render, so there is something to
  show even then.
  """
  @type endpoint :: %{
          path: path(),
          host: String.t() | nil,
          base_url: String.t(),
          locality: locality()
        }

  # `host.docker.internal` and `172.17.0.1` are the host machine as seen from
  # inside a container, not a third party: they are the Docker gateway back to
  # the user's own loopback. `host.docker.internal:8000` is this project's own
  # shipped default (docker-compose.yml, .env.example), so calling it remote
  # would make the UI lie in the opposite direction for the standard setup.
  @local_hosts ~w(localhost 127.0.0.1 ::1 0.0.0.0 host.docker.internal 172.17.0.1)

  @doc """
  Returns true only when every inference path runs on this machine.

  False when any endpoint is remote *or* unreadable, so the privacy claim is
  made only where it is positively established.
  """
  @spec local?() :: boolean()
  def local?, do: Enum.all?(endpoints(), &(&1.locality == :local))

  @doc """
  Returns the destinations documents are sent to, as one string for UI copy.

  Whenever `local?/0` is false this is non-empty, so the copy naming a
  destination needs only a single translated string with a single binding. A
  path with a readable host contributes that host; an `:unknown` one contributes
  its configured URL instead, which is concrete enough to point the user at the
  setting to fix. Entries are deduplicated, sorted, and joined with `", "`.

  Returns `""` when everything is local — there is no destination to name, and
  the caller should be rendering the privacy copy rather than this.

  Never contains credentials: any URL it falls back to is passed through
  `redact_url/1`.
  """
  @spec destination_label() :: String.t()
  def destination_label do
    endpoints()
    |> Enum.reject(&(&1.locality == :local))
    |> Enum.map(&(&1.host || &1.base_url))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  @doc """
  Returns the hosts documents are sent to, deduplicated and sorted.

  Only nameable hosts appear: an `:unknown` endpoint contributes nothing, so
  this can be empty while `local?/0` is false. Use `destination_label/0` for UI
  copy that must always name something; use this when the host itself is the
  value being worked with.
  """
  @spec remote_hosts() :: [String.t()]
  def remote_hosts do
    endpoints()
    |> Enum.reject(&(&1.locality == :local or is_nil(&1.host)))
    |> Enum.map(& &1.host)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns the locality of each inference path, in a stable order.

  The two paths share a host whenever `:embedding`'s `:base_url` is unset, since
  it then falls back to the chat endpoint; they are reported separately anyway,
  so a caller can attribute egress to the setting that causes it.
  """
  @spec endpoints() :: [endpoint()]
  def endpoints do
    for {path, base_url} <- [chat: OpenAI.base_url(), embedding: Embedding.base_url()] do
      host = host(base_url)

      %{
        path: path,
        host: host,
        base_url: displayable_url(base_url),
        locality: classify(host)
      }
    end
  end

  @doc """
  Classifies one base URL without reading configuration.

  Exposed so callers checking an endpoint they already hold — a value being
  validated before it is saved, say — apply the same rule as the live settings.
  """
  @spec locality(term()) :: locality()
  def locality(base_url), do: base_url |> host() |> classify()

  # `URI.parse/1` reports a scheme-less value as having no host, and a bare
  # `"http://"` as having an empty one; neither names a machine, so both become
  # nil and are classified `:unknown` rather than falling through to `:remote`
  # with nothing to display.
  defp host(base_url) when is_binary(base_url) do
    case URI.parse(base_url).host do
      "" -> nil
      host -> host
    end
  end

  defp host(_base_url), do: nil

  defp classify(nil), do: :unknown

  defp classify(host) do
    # Hosts are case-insensitive; compare folded, but report the host as written.
    # Fold ASCII-only: full Unicode folding maps U+212A KELVIN SIGN onto `k`, so
    # `host.docKer.internal` would otherwise be granted the on-device promise.
    if String.downcase(host, :ascii) in @local_hosts, do: :local, else: :remote
  end

  # Everything up to and including the `@` that closes the userinfo, with an
  # optional `scheme://` kept in front of it. Anchored and non-greedy about the
  # authority (`[^/?#@]*` cannot cross into the path), so an `@` in a path —
  # `http://host/v1/@me` — is left alone.
  @credentials ~r{\A([a-zA-Z][a-zA-Z0-9+.\-]*://)?(?:[^/?#@]*@)?}

  @doc """
  Strips credentials from an operator-supplied URL so it is safe to show or log.

  Removes the userinfo (`http://user:secret@host`) and the whole query string,
  which is where a gateway-style endpoint carries its key.

  Works on the string rather than on a parsed `URI`, because nulling
  `URI.userinfo` does not: `URI.parse/1` fills `:userinfo` only when it finds a
  host, and `URI.to_string/1` re-emits the untouched `:authority` when it does
  not — so `"user:secret@llm:8000"` and `"http://user:secret@/v1"` both survive
  that redaction with the password intact. Those are exactly the values this
  module classifies `:unknown`, and `:unknown` is exactly when
  `destination_label/0` falls back to showing a URL.
  """
  @spec redact_url(String.t()) :: String.t()
  def redact_url(url) when is_binary(url) do
    url
    |> String.split(["?", "#"], parts: 2)
    |> hd()
    |> then(&Regex.replace(@credentials, &1, "\\1", global: false))
  end

  # A value that survives redaction as blank, or that is not a string at all, is
  # reported inspected, so the result is always non-empty and always renderable.
  # Note this inspects the *redacted* value: inspecting the raw one would put
  # back the credentials this exists to remove.
  defp displayable_url(base_url) when is_binary(base_url) do
    redacted = redact_url(base_url)

    if String.trim(redacted) == "", do: inspect(redacted), else: redacted
  end

  defp displayable_url(base_url), do: inspect(base_url)
end
