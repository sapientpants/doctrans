import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :doctrans, Doctrans.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "doctrans_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :doctrans, DoctransWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "yQE0h1z67LKlhGkLxGWPowtcNLMp88M/P6ND2fngrV0or4J1rFf2nXFiR4ETm7GM",
  live_view: [signing_salt: "P9wT4yH6jN2mV8kD0qL3xR7zB5cF1aG4"],
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use mocks for external services in tests
config :doctrans, :embedding_module, Doctrans.Search.EmbeddingMock
config :doctrans, :openai_module, Doctrans.Processing.OpenAIStub
config :doctrans, :pdf_extractor_module, Doctrans.Processing.PdfExtractorMock

# Use an isolated storage root for tests, outside the application directory, so
# the suite exercises the same nondefault root an operator gets from
# DOCTRANS_DATA_DIR. `config/runtime.exs` deliberately ignores that variable in
# :test, and `test/test_helper.exs` refuses to run against any other root.
config :doctrans, :uploads,
  upload_dir: Path.expand("../tmp/uploads_test", __DIR__),
  max_file_size: 100_000_000

# Use shorter retry delays for faster tests
config :doctrans, :retry,
  max_attempts: 2,
  base_delay_ms: 10,
  max_delay_ms: 50

# Disable health check worker in tests (makes real HTTP/DB calls)
config :doctrans, Doctrans.Resilience.HealthCheckWorker, enabled: false

# Disable the document sweeper in tests, for the same reason. Its first sweep is
# scheduled one minute after boot regardless of environment and the suite runs
# longer than that, so an enabled worker performs a real sweep of whatever upload
# root is configured when the timer fires -- the shared `tmp/uploads_test`, or the
# temporary root a sweeper test has just pointed `:uploads` at and filled with the
# fixtures it is about to assert on. `sweep_now/0` still works while disabled, so
# the tests that drive a sweep on demand are unaffected.
config :doctrans, Doctrans.Documents.SweeperWorker, enabled: false

# Oban configuration for testing
config :doctrans, Oban,
  repo: Doctrans.Repo,
  plugins: [
    Oban.Plugins.Pruner
  ],
  queues: false,
  testing: :inline

# Extraction bounds are deliberately small in tests: the suite drives the bounds
# with fake poppler executables, and the production ceilings would make a test
# that exercises a timeout take two minutes to do it. Tests that need a specific
# bound still override it locally.
config :doctrans, :pdf_extraction,
  dpi: 150,
  timeout: 5_000,
  info_timeout: 2_000,
  job_timeout: 30_000,
  max_pages: 1_000,
  max_page_pixels: 40_000_000,
  max_image_bytes: 20_000_000

# The dev-only routes are compiled into the test router as well, so the
# dashboard's CSP nonce (U13) is covered where it actually renders rather than
# only at the plug. This mirrors config/dev.exs; no other code reads the flag.
config :doctrans, dev_routes: true
