# Doctrans

A Phoenix LiveView application for translating PDF documents using local AI models via
Ollama. Upload a PDF, and Doctrans will extract each page as an image, use a vision model
to extract text as Markdown, and then translate it to your target language.

## Features

- PDF upload with automatic page extraction
- Background processing pipeline (image extraction → OCR → translation)
- Split-screen document viewer (original page image | translated markdown)
- Real-time progress updates via LiveView
- Progressive loading - view completed pages while processing continues
- Hybrid search - semantic + keyword search across all pages
- Document sorting by date or name

## Prerequisites

- **Erlang** 27.0+
- **Elixir** 1.18+
- **Node.js** 20+ - for asset compilation (esbuild, Tailwind)
- **PostgreSQL** 14+ with pgvector extension
- **poppler-utils** - for PDF page extraction (`pdftoppm`)
- **Ollama** - local AI model server

### Installing poppler-utils

```bash
# macOS
brew install poppler

# Ubuntu/Debian
sudo apt-get install poppler-utils

# Fedora
sudo dnf install poppler-utils
```

### Installing Ollama

```bash
# macOS
brew install ollama

# Linux
curl -fsSL https://ollama.com/install.sh | sh
```

### Required Ollama Models

```bash
ollama pull ministral-3:14b     # Model for OCR and translation
ollama pull qwen3-embedding:0.6b # Embedding model for search
```

Ensure Ollama is running before starting Doctrans:

```bash
ollama serve
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

Run the app with Docker Compose while using Ollama on your host machine:

```bash
# Ensure Ollama is running on your host
ollama serve

# Start PostgreSQL and the app (migrations run automatically)
docker compose up
```

Visit [http://localhost:4000](http://localhost:4000) in your browser.

The app connects to Ollama via `host.docker.internal:11434`. For Linux, the `extra_hosts`
directive in `docker-compose.yml` maps this automatically.

To customize environment variables, copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

## Usage

1. Click **Upload** on the dashboard
2. Drag and drop PDF files or click to browse
3. Select target language
4. Click **Start Translation**

The document appears on the dashboard with a progress indicator. Click it to view completed pages while processing continues.

### Search

Use the search input on the dashboard to find content across all documents. Search combines
semantic similarity (AI embeddings) with keyword matching. Press Enter to see results, then
click a result to jump directly to that page.

## Configuration

Configuration in `config/config.exs`:

```elixir
# Ollama settings (OLLAMA_HOST env var overrides base_url)
config :doctrans, :ollama,
  base_url: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  vision_model: "ministral-3:14b",
  text_model: "ministral-3:14b",
  timeout: 300_000

# Embedding settings
config :doctrans, :embedding,
  base_url: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  model: "qwen3-embedding:0.6b",
  timeout: 60_000

# Upload settings
config :doctrans, :uploads,
  upload_dir: Path.expand("../priv/static/uploads", __DIR__),
  max_file_size: 100_000_000  # 100MB

# Default language settings
config :doctrans, :defaults,
  source_language: "de",
  target_language: "en"
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API URL |
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

### Ollama connection refused

```text
** (Req.TransportError) connection refused
```

Ensure Ollama is running (`ollama serve`) and accessible at the configured `OLLAMA_HOST`.
For Docker, verify `host.docker.internal` resolves correctly.

### Missing Ollama models

```text
model "ministral-3:14b" not found
```

Pull the required models before starting:

```bash
ollama pull ministral-3:14b
ollama pull qwen3-embedding:0.6b
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
