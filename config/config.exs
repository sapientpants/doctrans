# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :doctrans,
  ecto_repos: [Doctrans.Repo],
  generators: [timestamp_type: :utc_datetime]

# Ollama configuration for AI models
# OLLAMA_HOST env var allows overriding for Docker (e.g., http://host.docker.internal:11434)
config :doctrans, :ollama,
  base_url: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  vision_model: "ministral-3:14b",
  text_model: "ministral-3:14b",
  timeout: 300_000

# File upload configuration
config :doctrans, :uploads,
  upload_dir: Path.expand("../priv/static/uploads", __DIR__),
  max_file_size: 100_000_000

# Document sweeper configuration (cleans up orphaned directories)
config :doctrans, Doctrans.Documents.SweeperWorker,
  enabled: true,
  interval_hours: 6,
  grace_period_hours: 24

# Default language settings
config :doctrans, :defaults,
  source_language: "de",
  target_language: "en"

# Gettext configuration for i18n
config :doctrans, DoctransWeb.Gettext,
  default_locale: "en",
  locales: ~w(da de en es fr it nl no pl pt sv)

# Embedding configuration for semantic search
config :doctrans, :embedding,
  base_url: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  model: "qwen3-embedding:0.6b",
  timeout: 60_000

# Configures the endpoint
config :doctrans, DoctransWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DoctransWeb.ErrorHTML, json: DoctransWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Doctrans.PubSub,
  live_view: [signing_salt: "MtYXaIpH"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :doctrans, Doctrans.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  doctrans: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  doctrans: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
