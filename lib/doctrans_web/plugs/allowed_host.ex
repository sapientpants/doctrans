defmodule DoctransWeb.Plugs.AllowedHost do
  @moduledoc """
  Refuses a request whose `Host` is not a name this deployment answers to.

  Doctrans has no authentication, so the one thing standing between a page in
  the user's browser and every document on the machine is the browser's
  same-origin policy. DNS rebinding defeats it: once `attacker.example`
  resolves to `127.0.0.1`, that page is same-origin with the app and can
  `fetch('/')` for the document list, then every `/documents/:id/export.md`,
  and post the Markdown to a server it controls (#260). The socket's origin
  allowlist does not help, because plain GETs open no socket.

  What the rebound page cannot forge is the `Host` header: the browser sends
  the name it typed, so a request for a host this deployment does not answer
  to is refused with 421 Misdirected Request before any other plug runs. The
  list comes from `config :doctrans, :allowed_hosts`, which `config/runtime.exs`
  builds from the same names as the socket's origin allowlist: the loopback
  names, `PHX_HOST`, and a specific `PHX_BIND_IP`. Entries are lower-case, and
  the request host is compared in lower case, as browsers send it; Bandit keeps
  an IPv6 literal in its brackets, so `[::1]` is spelled that way on both sides.

  This plug does not reach `/live`: Phoenix dispatches socket mounts before the
  plug pipeline, which is why the origin allowlist is still required (#259).
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if String.downcase(conn.host) in allowed_hosts() do
      conn
    else
      Logger.warning(
        "Refused a request for host #{inspect(conn.host)}: not one of the hosts this " <>
          "deployment answers to. Set PHX_HOST to the name the browser types."
      )

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(421, misdirected_message(conn.host))
      |> halt()
    end
  end

  defp allowed_hosts, do: Application.fetch_env!(:doctrans, :allowed_hosts)

  defp misdirected_message(host) do
    "Misdirected request: this Doctrans deployment does not answer to the host " <>
      "#{inspect(host)}. Reach it as localhost, 127.0.0.1 or [::1], or set PHX_HOST " <>
      "to the name the browser types."
  end
end
