import Config

# Load defaults before reading runtime settings, in every environment.
Doctrans.EnvLoader.load()

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/doctrans start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :doctrans, DoctransWeb.Endpoint, server: true
end

# Resolve credentials when the release starts, for both API clients.
#
# The host is checked here, once, before either client sees it. Finch refuses a
# URL without an http(s) scheme or a host by raising an `ArgumentError` whose
# message quotes the whole URL -- credentials included, since an operator may
# write `http://user:secret@host`. A value such as `user:secret@llm:8000`, the
# scheme left off, would otherwise raise on every health probe and every page
# job, and the secret would land in the log and in `oban_jobs.errors` each time.
# Refusing at boot names the variable and shows only the redacted value.
case System.get_env("OPENAI_HOST") do
  nil ->
    :ok

  host ->
    unless Doctrans.Config.Inference.well_formed_url?(host) do
      raise "OPENAI_HOST must be an http(s) URL with a host, such as " <>
              "http://localhost:8000, got: #{Doctrans.Config.Inference.redact_url(host)}"
    end
end

for config_key <- [:openai, :embedding] do
  for {env_key, option} <- [{"OPENAI_HOST", :base_url}, {"OPENAI_API_KEY", :api_key}],
      value = System.get_env(env_key),
      not is_nil(value) do
    config :doctrans, config_key, [{option, value}]
  end
end

# One storage root for writing and serving: `DOCTRANS_DATA_DIR` moves documents,
# generated page images, and converted PDFs off the application directory, and the
# endpoint serves page images from the same place. Left unset, the default
# resolves at runtime (see `Doctrans.Config.Uploads.upload_dir/0`).
#
# Never honoured in :test. The suite owns the root configured in `config/test.exs`
# and deletes directories beneath it, so reading the variable here would let
# `mix test` erase the documents of an operator who set it in `.env`.
if config_env() != :test do
  case System.get_env("DOCTRANS_DATA_DIR") do
    nil ->
      :ok

    "" ->
      raise "DOCTRANS_DATA_DIR is set but empty; unset it to use the default storage root"

    dir ->
      if Path.type(dir) != :absolute do
        raise "DOCTRANS_DATA_DIR must be an absolute path, got: #{dir}. " <>
                "A relative path resolves against the working directory the " <>
                "application happens to start in."
      end

      config :doctrans, :uploads, upload_dir: Path.expand(dir)
  end
end

# The listener, for every environment that starts a server. `config/test.exs`
# pins its own loopback port and never serves, so it is left alone.
#
# Doctrans is a local, single-user app with no authentication, so the endpoint
# binds on loopback only. PHX_BIND_IP is the one explicit way to widen that:
# PHX_BIND_IP=0.0.0.0 (or :: for IPv6) accepts connections on every interface,
# which is what a container needs and what reaches the app from a trusted LAN —
# you do so at your own risk, since there is no auth to pass.
#
# The value has to be parsed here rather than passed through: Bandit types `:ip`
# as `:inet.socket_address()` and hands it to `:gen_tcp.listen/2`, which exits
# with :badarg on a binary, so a textual address stops the endpoint from ever
# starting. `:inet.parse_address/1` takes a charlist and accepts IPv4 and IPv6
# literals alike; it resolves no host names, which is why the error below says so.
#
# The parse stays inline rather than in a helper module. This file runs after
# compilation (it calls `Doctrans.EnvLoader.load/0` above), so a helper would be
# reachable; but the parse is one `case`, nothing else needs it, and keeping it
# beside the variable it reads shows how that variable is interpreted.
if config_env() != :test do
  bind_ip_string = System.get_env("PHX_BIND_IP") || "127.0.0.1"

  bind_ip =
    case :inet.parse_address(String.to_charlist(bind_ip_string)) do
      {:ok, address} ->
        address

      {:error, _reason} ->
        raise "PHX_BIND_IP must be an IPv4 or IPv6 address literal, got: #{bind_ip_string}. " <>
                "Use 127.0.0.1 to bind on loopback, 0.0.0.0 (or :: for IPv6) to accept " <>
                "connections on every interface. Host names are not resolved."
    end

  port = String.to_integer(System.get_env("PORT") || "4000")

  # The hosts this deployment answers to, stated once for every environment
  # that serves. The list does two jobs: `DoctransWeb.Plugs.AllowedHost` refuses
  # any request whose `Host` is not on it, and the LiveView socket's
  # `check_origin` admits a handshake only from an Origin on it.
  #
  # Both guard against the same page. Doctrans has no authentication, so a
  # DNS-rebinding page is the attacker that matters: once its hostname resolves
  # to 127.0.0.1 it is same-origin in the browser's eyes. Over plain GETs it
  # reads `/` for the document list and every `/documents/:id/export.md` (#260);
  # over a socket opened from its own Origin it can delete every document (#259;
  # development used to set `check_origin: false`, which admits any Origin).
  # What that page cannot forge is the name the browser typed: its requests
  # carry its own hostname as `Host` and `Origin`, so an explicit list of the
  # names this deployment is reached by refuses both. Both quickstarts (`mix
  # phx.server` and `docker compose up`) run the development config, so the list
  # is built here rather than in `prod.exs`.
  #
  # The list: the loopback names a local browser can type, PHX_HOST when set
  # (the name the browser types to reach a deployment), and PHX_BIND_IP when it
  # is one specific address, since a browser reaches an endpoint bound there by
  # typing that address. 0.0.0.0 and :: name no host a browser can type and add
  # nothing; a deployment reached over a LAN names its host through PHX_HOST.
  # Entries are hosts without a port: the plug compares `conn.host`, which Bandit
  # parses without the port, and Phoenix compares only the host when an origin
  # entry names no scheme or port, so `http://localhost:4000` and
  # `http://localhost:4321` both match `//localhost`. An IPv6 literal keeps its
  # brackets on both sides, which is how Bandit reports it and how a browser
  # types it.
  #
  # Not `check_origin: :conn`: that compares Origin against the request Host,
  # and under rebinding both read the attacker's name.
  loopback_hosts = ["localhost", "127.0.0.1", "[::1]"]

  # Checked here rather than at the first request: Phoenix parses the origin
  # list lazily, and a bad entry either raises inside the transport, long after
  # boot and with the variable's name nowhere in the error, or quietly matches
  # no browser at all. `URI.parse/1` is lenient about the second kind: "fe80::1"
  # parses to host "fe80" and "http://doctrans.lan" to host "http", so the value
  # is accepted only when it is exactly the host parsing gives back — a bare name
  # or IPv4 literal, or an IPv6 literal in brackets. Lower-cased for the entry,
  # because browsers send the Host and Origin in lower case and both checks
  # compare lower-case; the advertised URL below keeps the value as typed.
  phx_hosts =
    case System.get_env("PHX_HOST") do
      nil ->
        []

      phx_host ->
        host = URI.parse("//#{phx_host}").host || ""

        well_formed? =
          case phx_host do
            "[" <> _ ->
              phx_host == "[#{host}]" and
                match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(host)))

            _ ->
              phx_host == host and
                Regex.match?(~r/\A[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?\z/, host)
          end

        unless well_formed? do
          raise "PHX_HOST must be a host name or IP address literal, with an IPv6 literal in " <>
                  "brackets (such as [fe80::1]) and no scheme, port or path, got: " <>
                  "#{inspect(phx_host)}. It is the host the browser types to reach this " <>
                  "deployment; unset it when only the loopback names (localhost, 127.0.0.1, " <>
                  "[::1]) apply."
        end

        [String.downcase(phx_host)]
    end

  bind_hosts =
    case bind_ip do
      unspecified when unspecified in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}] ->
        []

      ipv6 when tuple_size(ipv6) == 8 ->
        ["[#{:inet.ntoa(ipv6)}]"]

      ipv4 ->
        ["#{:inet.ntoa(ipv4)}"]
    end

  allowed_hosts = Enum.uniq(loopback_hosts ++ phx_hosts ++ bind_hosts)

  config :doctrans, :allowed_hosts, allowed_hosts

  config :doctrans, DoctransWeb.Endpoint,
    check_origin: Enum.map(allowed_hosts, &("//" <> &1)),
    http: [
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: bind_ip,
      port: port
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :doctrans, Doctrans.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # The advertised URL is the address this app reports as its own, and it has to
  # describe what the deployment actually serves.
  #
  # Its `:host` no longer gates the socket: the origin allowlist above is
  # explicit, so `url[:host]` is not what the handshake's `Origin` is compared
  # against. PHX_HOST still has to be whatever the browser types, because the
  # same variable feeds that allowlist — a deployment reached by a name it does
  # not list renders once and then goes dead.
  #
  # The scheme and port are what the app hands out — `Endpoint.url/0`,
  # `url(~p"...")`, the "Access ... at" line logged at boot. Hardcoding https on
  # 443 while the listener speaks plain HTTP on PORT makes all of those name an
  # address that does not exist. Serving HTTP directly is the default; PHX_SCHEME
  # =https restores the behind-a-TLS-proxy case, where the proxy terminates on 443
  # and this container still listens on PORT.
  scheme = System.get_env("PHX_SCHEME") || "http"

  # The listening port, read the same way the listener block above reads it.
  port = String.to_integer(System.get_env("PORT") || "4000")

  url_port =
    case scheme do
      "http" ->
        port

      "https" ->
        443

      other ->
        raise "PHX_SCHEME must be \"http\" or \"https\", got: #{other}. " <>
                "Set it to https only when a TLS proxy terminates in front of this app; " <>
                "the app itself always serves plain HTTP on PORT."
    end

  config :doctrans, DoctransWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: secret_key_base]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :doctrans, DoctransWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :doctrans, DoctransWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
