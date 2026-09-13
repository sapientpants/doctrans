# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :doctrans,
  env: config_env(),
  ecto_repos: [Doctrans.Repo],
  generators: [timestamp_type: :utc_datetime]

# Page and chunk vector columns require this decoder in every environment.
config :doctrans, Doctrans.Repo, types: Doctrans.PostgrexTypes

# OpenAI-compatible API configuration for AI models (OMLX).
# OPENAI_HOST / OPENAI_API_KEY env vars allow overriding (e.g., Docker:
# http://host.docker.internal:8000). Defaults match the local OMLX server.
config :doctrans, :openai,
  base_url: "http://localhost:8000",
  api_key: nil,
  vision_model: "mlx-community/Qwen3.5-9B-MLX-4bit",
  translation_model: "mlx-community/Qwen3.6-35B-A3B-4bit",
  chat_model: "mlx-community/Qwen3.6-35B-A3B-4bit"

# Circuit breaker configuration for resilience
config :doctrans, :circuit_breakers,
  openai_api: [
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
#
# Extraction runs in a single-slot queue against external poppler commands, so
# every bound here exists to keep one document from holding that slot:
# - timeout: milliseconds one `pdftoppm` render may take before its process
#   group is killed
# - info_timeout: the same deadline for the much cheaper `pdfinfo` call
# - job_timeout: milliseconds the whole extraction job may take. It is also the
#   budget the extractor clamps each page render against, so per-page deadlines
#   cannot add up past it. Pages already rendered are kept, so a retry resumes
#   rather than restarting. `RunCleanupJob` shares this single-slot queue, so
#   this is also how long cleanup can be kept waiting.
# - max_pages: documents above this are rejected before any page is rendered
# - max_page_pixels: a page whose geometry would rasterize to more pixels than
#   this at the configured :dpi is rejected before it is rendered. A maximal PDF
#   media box renders to gigabytes well inside the deadline, so this is the bound
#   that has to come first. The default admits an E-size (36x48in) drawing at
#   150 dpi.
# - max_image_bytes: a rendered page above this is deleted and reported, since
#   the image is about to be sent to a model; lower :dpi is the usual answer
#
# Optional keys:
# - pdftoppm_path / pdfinfo_path: explicit paths to the poppler executables,
#   for installations that are not on $PATH
# - search_dirs: directories to fall back to when $PATH has no match, for a
#   daemon started with a slim environment. Set to [] to require $PATH.
config :doctrans, :pdf_extraction,
  dpi: 150,
  timeout: 120_000,
  info_timeout: 15_000,
  job_timeout: 3_600_000,
  max_pages: 1_000,
  max_page_pixels: 40_000_000,
  max_image_bytes: 20_000_000

# Document conversion configuration (for Word, OpenDocument, etc.)
# Requires LibreOffice to be installed:
# - macOS: brew install --cask libreoffice
# - Ubuntu: apt-get install libreoffice-writer-nogui
#
# Optional keys:
# - timeout (default 120_000): milliseconds a conversion may take before
#   the soffice process is killed
# - soffice_path: explicit path to the soffice executable, e.g. an
#   installation under a Nix store that is not on $PATH
# - search_paths: extra absolute paths checked when soffice is not on
#   $PATH (defaults cover Homebrew, macOS, and Debian/Ubuntu layouts)
config :doctrans, :document_conversion, timeout: 120_000

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

# Embedding configuration for semantic search. A nil URL uses the OpenAI endpoint.
config :doctrans, :embedding,
  base_url: nil,
  api_key: nil,
  model: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ"

# Oban configuration for persistent job queuing
#
# Queue concurrency values:
# - pdf_extraction: 1 - Sequential extraction to ensure pages are processed in order
# - llm_processing: 1 - Sequential processing to process pages in order (one at a time)
# - embedding_generation: 2 - Indexing is bounded so a backlog of pages cannot open
#   an unbounded number of concurrent embedding requests, but stays above one so a
#   slow page does not stall the rest of the queue. Chunks within a page are
#   embedded one at a time regardless.
# - health_check: 1 - Single worker for periodic health checks (cron job)
config :doctrans, Oban,
  repo: Doctrans.Repo,
  plugins: [
    # Oban prunes after 60 seconds by default, which is too eager to be useful
    # here: a settled indexing job is the record that says "this revision was
    # already given up on", and startup recovery reads it to avoid re-queueing
    # the same failure on every boot. A week of history costs little for a
    # single-user app and makes a failed run diagnosable after the fact.
    {Oban.Plugins.Pruner, max_age: {7, :days}},
    # An orphaned `executing` job — one whose node was killed rather than shut
    # down — blocks both recovery and re-enqueue for the page it holds until it
    # is rescued, so the window should not be much longer than the work itself.
    # A page's chunks are embedded one at a time against a 60s-per-call timeout
    # and a dense page yields a handful of chunks, so 15 minutes leaves a wide
    # margin over a realistic run while cutting the stall from an hour.
    {Oban.Lifeline, rescue_after: {15, :minutes}},
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Doctrans.Jobs.HealthCheckJob}]}
  ],
  queues: [
    pdf_extraction: 1,
    llm_processing: 1,
    embedding_generation: 2,
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
  pubsub_server: Doctrans.PubSub

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
