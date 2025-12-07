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
  pool_size: System.schedulers_online() * 2,
  types: Doctrans.PostgrexTypes

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :doctrans, DoctransWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "yQE0h1z67LKlhGkLxGWPowtcNLMp88M/P6ND2fngrV0or4J1rFf2nXFiR4ETm7GM",
  server: false

# In test we don't send emails
config :doctrans, Doctrans.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use mocks for external services in tests
config :doctrans, :embedding_module, Doctrans.Search.EmbeddingMock
config :doctrans, :ollama_module, Doctrans.Processing.OllamaMock
config :doctrans, :pdf_extractor_module, Doctrans.Processing.PdfExtractorMock

# Use isolated upload directory for tests to avoid conflicts with development
config :doctrans, :uploads,
  upload_dir: Path.expand("../priv/static/uploads_test", __DIR__),
  max_file_size: 100_000_000
