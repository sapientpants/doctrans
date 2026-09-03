# Doctrans

A privacy-first Phoenix LiveView application for translating documents using local AI
models with oMLX (an OpenAI-compatible API server). Upload a PDF, Word, OpenDocument, or RTF file, and Doctrans will extract
each page as an image, use a vision model to extract text as Markdown, and then translate it
to your target language. All processing happens on your device — no data is ever sent to
external services.

## Features

- **100% local processing** — your documents never leave your device
- Upload PDF, DOCX, DOC, ODT, and RTF files (up to 10 at once)
- Background processing pipeline (image extraction → OCR → translation)
- Split-screen document viewer (original page image | translated markdown)
- Real-time progress updates via LiveView
- Progressive loading - view completed pages while processing continues
- Document chat (RAG) - ask questions about your translated documents
- Hybrid search - semantic + keyword search across all pages
- Reprocess pages with different AI models
- Zoom controls for page images
- Document sorting by date or name
- Internationalized UI (11 locales: da, de, en, es, fr, it, nl, no, pl, pt, sv)

## Prerequisites

- **Erlang** 27.0+
- **Elixir** 1.18+
- **PostgreSQL** 14+ with pgvector extension
- **poppler-utils** - for PDF page extraction (`pdftoppm`)
- **LibreOffice** (optional) - for DOCX, DOC, ODT, and RTF conversion
- **oMLX** - local inference server (OpenAI-compatible API)

### Installing poppler-utils

```bash
# macOS
brew install poppler

# Ubuntu/Debian
sudo apt-get install poppler-utils

# Fedora
sudo dnf install poppler-utils
```

### Installing LibreOffice (optional)

Required only for non-PDF formats (DOCX, DOC, ODT, RTF):

```bash
# macOS
brew install --cask libreoffice

# Ubuntu/Debian
sudo apt-get install libreoffice-writer-nogui

# Fedora
sudo dnf install libreoffice-writer
```

### Installing oMLX (OpenAI-compatible API Server)

```bash
# macOS
brew install jundot/omlx

# Linux
# Build from source: https://github.com/jundot/omlx
```

### Pull Required Models

```bash
omlx serve --model qwen3.5:9b           # Vision model for OCR and text extraction
omlx serve --model translategemma:12b   # Text model for translation
omlx serve --model qwen3-embedding:0.6b # Embedding model for search and chat
```

Ensure oMLX is running before starting Doctrans:

```bash
omlx serve
```

## Getting Started

```bash
git clone https://github.com/sapientpants/doctrans.git
cd doctrans
mix setup
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000) in your browser.

## Docker Setup

Run the app with Docker Compose while using oMLX on your host machine:

```bash
# Ensure oMLX is running on your host
omlx serve

# Start PostgreSQL and the app (migrations run automatically)
docker compose up
```

Visit [http://localhost:4000](http://localhost:4000) in your browser.

The app connects to oMLX at `host.docker.internal:8000`. For Linux, the `extra_hosts`
directive in `docker-compose.yml` maps this automatically.

To customize environment variables, copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

## Usage

1. Click **Upload** on the dashboard
2. Drag and drop files (PDF, DOCX, DOC, ODT, RTF) or click to browse
3. Select target language
4. Click **Start Translation**

The document appears on the dashboard with a progress indicator. Click it to view completed pages while processing continues.

### Search

Use the search input on the dashboard to find content across all documents. Search combines
semantic similarity (AI embeddings) with keyword matching. Press Enter to see results, then
click a result to jump directly to that page.

### Document Chat

Open the chat panel on any document to ask questions about its content. The chat uses
retrieval-augmented generation (RAG) to find relevant pages via semantic search and answer
using the AI model. Chat is available once page embeddings have been generated.

## Configuration

Configuration in `config/config.exs`:

```elixir
# API server settings (OPENAI_HOST env var overrides base_url)
config :doctrans, :openai,
  base_url: System.get_env("OPENAI_HOST", "http://localhost:8000"),
  vision_model: "mlx-community/Qwen3.5-9B-MLX-4bit",
  translation_model: "mlx-community/Qwen3.6-35B-A3B-4bit",
  chat_model: "mlx-community/Qwen3.6-35B-A3B-4bit",
  timeout: 300_000

# Embedding settings
config :doctrans, :embedding,
  base_url: System.get_env("OPENAI_HOST", "http://localhost:8000"),
  model: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
  timeout: 60_000

# Circuit breaker configuration for resilience
config :doctrans, :circuit_breakers,
  openai_api: [strategy: {:standard, 5, 60_000}, refresh: 30_000],
  embedding_api: [strategy: {:standard, 3, 30_000}, refresh: 15_000]

# Retry configuration for exponential backoff
config :doctrans, :retry,
  max_attempts: 3,
  base_delay_ms: 2_000,
  max_delay_ms: 30_000

# Upload settings
config :doctrans, :uploads,
  upload_dir: Path.expand("../priv/static/uploads", __DIR__),
  max_file_size: 100_000_000  # 100MB

# PDF extraction configuration
config :doctrans, :pdf_extraction, dpi: 150

# Document conversion timeout (for DOCX, ODT, RTF via LibreOffice)
config :doctrans, :document_conversion, timeout: 120_000

# Default language settings
config :doctrans, :defaults,
  source_language: "de",
  target_language: "en"
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_HOST` | `http://localhost:8000` | OpenAI-compatible API URL |
| `DATABASE_HOST` | `localhost` | PostgreSQL hostname (dev/test) |
| `DATABASE_URL` | - | Full database URL (required in production) |
| `PORT` | `4000` | Phoenix server port |
| `PHX_HOST` | `localhost` | Phoenix host for URL generation |
| `SECRET_KEY_BASE` | - | Secret key for signing (required in production) |
| `POOL_SIZE` | `10` | Database connection pool size |

## Development

```bash
mix test              # Run tests
mix precommit         # Run all checks (compile, deps.unlock, deps.audit, format, credo, sobelow, test)
mix credo --strict    # Static code analysis
mix sobelow --config  # Security analysis
mix dialyzer          # Type checking (first run builds PLT)
mix deps.audit        # Dependency vulnerability scanning
mix coveralls.html    # Test coverage report (80% minimum required)
iex -S mix phx.server # Interactive console
```

### Code Quality Standards

This project enforces strict code quality:

- **80% test coverage** minimum (enforced in CI)
- **500-line module limit** (enforced via pre-commit hook)
- **Strict Credo checks** including cyclomatic complexity, nesting depth, and code duplication
- **Security scanning** via Sobelow and dependency auditing
- **Type checking** via Dialyzer with strict flags

### Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) for automated git hooks:

```bash
pip install pre-commit
pre-commit install
```

Hooks run automatically on commit and include:

- Code formatting (`mix format`)
- Compilation with warnings as errors
- Credo strict mode
- Sobelow security analysis
- Module size limit check (500 lines max)
- Dependency vulnerability audit
- Test suite with coverage

Run manually with:

```bash
pre-commit run --all-files
```

### Commit Message Format

This project enforces [Conventional Commits](https://conventionalcommits.org/). All commit
messages must follow this format:

```text
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Allowed types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `build`, `ci`,
`perf`, `revert`

**Scope is required.** Examples:

- `feat(auth): add user login`
- `fix(api): resolve timeout issue`
- `docs(readme): update setup instructions`
- `test(pipeline): add integration tests`

### CI/CD

GitHub Actions runs on every push and PR to `main`:

- Pre-commit hooks (formatting, linting, security checks)
- Full test suite with 80% coverage requirement
- Dialyzer type checking
- Uncommitted changes detection

## Troubleshooting

### API server connection refused

```text
** (Req.TransportError) connection refused
```

Ensure oMLX is running (`omlx serve`) and accessible at the configured `OPENAI_HOST`.
For Docker, verify `host.docker.internal` resolves correctly.

### Model not found

```text
model "mlx-community/Qwen3.5-9B-MLX-4bit" not found
```

Pull the required models before starting:

```bash
omlx serve --model mlx-community/Qwen3.5-9B-MLX-4bit
omlx serve --model mlx-community/Qwen3.6-35B-A3B-4bit
omlx serve --model mlx-community/Qwen3-Embedding-8B-4bit-DWQ
```

### PDF processing fails

```text
** (ErlangError) pdftoppm: command not found
```

Install poppler-utils (see Prerequisites). On macOS: `brew install poppler`

### Database connection errors

```text
** (Postgrex.Error) FATAL: password authentication failed
```

Verify PostgreSQL is running and credentials match your config.
For Docker: `docker compose up db` starts the database with default credentials.

### pgvector extension missing

```text
** (Postgrex.Error) ERROR: type "vector" does not exist
```

Ensure you're using a PostgreSQL image with pgvector (e.g., `pgvector/pgvector:pg18`)
or install the extension manually: `CREATE EXTENSION vector;`

## License

MIT
