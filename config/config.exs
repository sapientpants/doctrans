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

# Circuit breaker configuration for resilience
config :doctrans, :circuit_breakers,
  ollama_api: [
    strategy: {:standard, 5, 60_000},
    refresh: 30_000
  ],
  embedding_api: [
    strategy: {:standard, 3, 30_000},
    refresh: 15_000
  ]

# Retry configuration for exponential backoff
config :doctrans, :retry,
  max_attempts: 3,
  base_delay_ms: 2_000,
  max_delay_ms: 30_000

# File upload configuration
config :doctrans, :uploads,
  upload_dir: Path.expand("../priv/static/uploads", __DIR__),
  max_file_size: 100_000_000

# PDF extraction configuration
# Higher DPI = better text recognition but larger files
config :doctrans, :pdf_extraction, dpi: 150

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

# Oban configuration for persistent job queuing
#
# Queue concurrency values:
# - pdf_extraction: 50 - High concurrency for CPU-bound PDF page extraction (pdftoppm)
# - llm_processing: 10 - Lower concurrency to avoid overwhelming Ollama API
# - embedding_generation: 20 - Moderate concurrency for embedding API calls
# - health_check: 1 - Single worker for periodic health checks (cron job)
config :doctrans, Oban,
  repo: Doctrans.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Doctrans.Jobs.HealthCheckJob}]}
  ],
  queues: [
    pdf_extraction: 50,
    llm_processing: 10,
    embedding_generation: 20,
    health_check: 1
  ]

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
# Format: timestamp metadata[level] message
# Metadata includes request_id (Phoenix), mfa (module.function/arity)
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :mfa]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
