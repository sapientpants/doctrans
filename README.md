# Doctrans

A privacy-first Phoenix LiveView application for translating documents using local AI
models through an OpenAI-compatible API server such as oMLX. Upload a PDF, Word, OpenDocument,
or RTF file, and Doctrans will extract each page as an image, use a vision model to extract
text as Markdown, and then translate it to your target language. Processing stays local when
you use a local inference server; configuring a remote endpoint sends document content to that server.

Doctrans is a local, single-user application with no authentication. Keep access restricted
to your device or a trusted network.

## Features

- **Local AI processing** — use a local inference server to keep document content on your device
- Upload PDF, DOCX, DOC, ODT, and RTF files (up to 10 at once, 100 MB per file)
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

- **Erlang/OTP** and **Elixir** - exact versions are pinned in [`mise.toml`](mise.toml),
  which CI and local tooling both read; run `mise install` to match them
  (`mix.exs` independently requires `~> 1.20`)
- **PostgreSQL** with pgvector extension (CI uses PostgreSQL 17; Docker Compose uses 18)
- **poppler-utils** - for PDF page extraction (`pdftoppm`)
- **LibreOffice** (optional) - for DOCX, DOC, ODT, and RTF conversion
- **OpenAI-compatible inference server** - vision, translation/chat, and embedding models
  (the defaults target oMLX on Apple Silicon)

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

### Installing oMLX (Apple Silicon macOS)

Follow the [oMLX installation and quickstart guide](https://github.com/jundot/omlx#install).
For Homebrew:

```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew install jundot/omlx/omlx
omlx serve
```

On Linux, use a compatible inference server or connect to oMLX running on a Mac.

### Configure Required Models

Download models through oMLX's model management UI or place them in its model directory.
The Doctrans defaults in `config/config.exs` are:

| Purpose | Model |
|---------|-------|
| Vision / OCR | `mlx-community/Qwen3.5-9B-MLX-4bit` |
| Translation and chat | `mlx-community/Qwen3.6-35B-A3B-4bit` |
| Embeddings | `mlx-community/Qwen3-Embedding-8B-4bit-DWQ` |

Set the model names in `config/config.exs` to the exact IDs exposed by your server's
`/v1/models` endpoint. Embeddings must contain at least 1,024 dimensions; Doctrans stores
only the first 1,024, so use a model compatible with that truncation.

## Getting Started

Start PostgreSQL with pgvector installed before running `mix setup`. Development uses
username `postgres`, password `postgres`, and database `doctrans_dev` on `localhost`.
`mix setup` creates the database and runs migrations, including enabling pgvector.

```bash
git clone https://github.com/sapientpants/doctrans.git
cd doctrans
mix setup
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000) in your browser.

## Docker Setup

Run the development app with Docker Compose while using an inference server on your host machine:

```bash
# Ensure oMLX is running on your host
omlx serve

# Start PostgreSQL and the app (migrations run automatically)
docker compose up
```

Visit [http://localhost:4000](http://localhost:4000) in your browser.

The app connects to the inference server at `http://host.docker.internal:8000`. The server must
listen on an interface reachable from the container. The `extra_hosts` directive in
`docker-compose.yml` supplies the host-gateway mapping, including on Linux.
The app and database ports are published on host loopback only. This Compose setup runs
in development mode with source files mounted for hot reload.

## Environment File

For a Docker-oriented starting point, copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

For a native run, change `OPENAI_HOST` to `http://localhost:8000`; the example uses Docker
hostnames. Development/test database credentials are configured in `config/dev.exs` and
`config/test.exs`; `DATABASE_URL` is only used in production.

The application loads an optional `.env` from the working directory at startup in
all environments, before reading runtime configuration. Precedence is **process
environment → `.env` → application defaults**, including explicitly empty values.
A missing file is fine. Set `DOCTRANS_ENV_FILE=/absolute/path/to/.env` to select a
specific file, including when running a release. Restart after changing the file.

Both API clients use `OPENAI_HOST` and `OPENAI_API_KEY`. When an inherited API
setting differs from the file, startup logs a warning identifying the winning
source without printing either value. To use the file's API key, start with
`env -u OPENAI_API_KEY mix phx.server`.

Tests follow the same loading rules; use `DOCTRANS_ENV_FILE` to select a separate
test file when needed. Settings read before runtime configuration, such as `DATABASE_HOST`
in dev/test and `PORT` in dev, must be exported in the process environment before starting Mix;
the runtime `.env` loader is too late to affect them. Setting `DATABASE_HOST` in the process
environment also makes the development endpoint bind to all interfaces.

The checked-in Compose file sets literal environment values, so copying `.env` does not
override those values. Edit `docker-compose.yml` or use a Compose override to change them.
The source mount makes the project `.env` available at `/app/.env`; values absent from the
container environment, such as `OPENAI_API_KEY`, can be loaded from it.

## Usage

1. Click **Upload** on the dashboard
2. Drag and drop files (PDF, DOCX, DOC, ODT, RTF) or click to browse
3. Select target language
4. Click **Start Translation**

The document appears on the dashboard with a progress indicator. Click it to view completed pages while
processing continues.

### Search

Use the search input on the dashboard to find content across all documents. Search combines
semantic similarity (AI embeddings) with keyword matching. Press Enter to see results, then
click a result to jump directly to that page.

### Document Chat

Open the chat panel on any document to ask questions about its content. The chat uses
retrieval-augmented generation (RAG) to find relevant document chunks via semantic search (with a page-level
fallback) and answer
using the AI model. Chat is available once chunk or page embeddings have been generated.
Chunk retrieval supplies the original source passage to chat: independently chunked translations
can expand or contract and are not reliably aligned. Whole-page fallback can use the full page
translation. Translations remain available in the document viewer.

Existing source embeddings remain usable without rebuilding: retrieval ignores legacy chunk
translations, including those in saved chat context. To rebuild existing chunks and remove their
old translation pairings, run `mix rechunk_documents` with the embedding server available.
Previously generated chat answers are retained.

Conversations are saved per document and can be resumed after reopening it.

## Configuration

Key settings in `config/config.exs` (timeouts shown below are the client defaults):

```elixir
# API server settings (runtime OPENAI_HOST / OPENAI_API_KEY override these)
config :doctrans, :openai,
  base_url: "http://localhost:8000",
  api_key: nil,
  vision_model: "mlx-community/Qwen3.5-9B-MLX-4bit",
  translation_model: "mlx-community/Qwen3.6-35B-A3B-4bit",
  chat_model: "mlx-community/Qwen3.6-35B-A3B-4bit",
  timeout: 300_000

# Embedding settings
config :doctrans, :embedding,
  base_url: nil, # Falls back to the OpenAI base_url
  api_key: nil,
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

# Document conversion timeout (for DOCX, DOC, ODT, RTF via LibreOffice)
config :doctrans, :document_conversion, timeout: 120_000

# Default language settings
config :doctrans, :defaults,
  source_language: "de",
  target_language: "en"
```

The default source language is German (`de`), and the target language is English (`en`).
The upload dialog selects the target language; change `source_language` in the configuration
for documents in another source language.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_HOST` | `http://localhost:8000` | Shared API base URL, without `/v1` or a trailing slash |
| `OPENAI_API_KEY` | unset | Bearer API key for both AI and embedding requests |
| `DOCTRANS_ENV_FILE` | `.env` | Environment file path, relative to the working directory or absolute |
| `DATABASE_HOST` | `localhost` | PostgreSQL hostname (dev/test) |
| `DATABASE_URL` | - | Full database URL (required in production) |
| `PORT` | `4000` | Phoenix server port (dev/prod; tests use 4002) |
| `PHX_BIND_IP` | `127.0.0.1` | Interface the production endpoint binds to (prod only). Doctrans has no authentication, so it defaults to loopback; set `PHX_BIND_IP=0.0.0.0` to expose it to a trusted LAN at your own risk |
| `PHX_HOST` | `example.com` | Production host for URL generation (dev uses `localhost`) |
| `PHX_SERVER` | unset | Set to `true` to enable the HTTP server when starting a release |
| `SECRET_KEY_BASE` | - | Secret key for signing (required in production) |
| `POOL_SIZE` | `10` | Production database connection pool size |
| `ECTO_IPV6` | unset | Enable IPv6 database sockets in production with `true` or `1` |
| `DNS_CLUSTER_QUERY` | unset | Optional DNS cluster discovery query in production |

## Development

```bash
mix test              # Run tests
mix precommit         # Run the full quality gate (defined in .pre-commit-config.yaml)
mix credo --strict    # Static code analysis
mix sobelow --config  # Security analysis
mix dialyzer          # Type checking (first run builds PLT)
mix hex.audit         # Security advisories and retired packages
mix coveralls.html    # Test coverage report (80% minimum required)
iex -S mix phx.server # Interactive console
```

### Code Quality Standards

This project enforces strict code quality:

- **80% test coverage** minimum (enforced in CI)
- **600-line module limit** (enforced via pre-commit hook)
- **Strict Credo checks** including cyclomatic complexity, nesting depth, and code duplication
- **Security scanning** via Sobelow and dependency auditing
- **Type checking** via Dialyzer with strict flags

### Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) for automated git hooks:

```bash
pip install pre-commit
pre-commit install
```

Hooks run automatically on commit, selected by the changed file types, and include:

- Code formatting check (`mix format --check-formatted`)
- Markdown/YAML and other file validation
- Translation completeness checks for changed locale files
- Compilation with warnings as errors
- Credo strict mode
- Sobelow security analysis
- Module size limit check (600 lines max)
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

- `feat(chat): add saved conversations`
- `fix(api): resolve timeout issue`
- `docs(readme): update setup instructions`
- `test(pipeline): add integration tests`

### CI/CD

GitHub Actions runs on pushes to `main` and pull requests targeting `main`:

- Pre-commit hooks (formatting, linting, security checks)
- Full test suite with 80% coverage requirement
- Dialyzer type checking
- Uncommitted changes detection
- Development Docker image build verification

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

Check that the model is downloaded and served, then compare its ID in `/v1/models` with the
configured model name. See [Configure Required Models](#configure-required-models).
`omlx serve` starts the server; it is not a model download command.

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

## Reprocessing a document

Open a document and choose **Reprocess document**. Select the extraction and
translation models, then confirm to rerun conversion (for office documents), page
rendering, extraction, translation, and search indexing from the original upload.
The dashboard and viewer show live progress, and pages become readable as they
finish. Existing generated pages and search results are replaced; the document
URL and chat history remain. Previous chat answers are historical.

Original uploads are retained until you delete the document. Generated files live
in separate processing-run directories; superseded output is cleaned up after a
restart. This uses more disk space than the previous source-deletion policy.
Only generated page images are served over HTTP; retained originals and converted
PDFs are excluded from static serving.
Documents imported before source retention was added may need to be uploaded
again before whole-document reprocessing is available. Single-page reprocessing
remains available when page images exist.

A document cannot restart while extraction or page-processing jobs are active,
including scheduled retries and suspended jobs. Let those jobs finish first.
Model choices are saved for the run and preserved during recovery. Page details
show the request model identifiers that produced the current extraction and
translation; older results with no recorded model display **Unknown**. Model
identifiers may be aliases and do not identify an immutable set of model weights.

### Incomplete model output

OCR, translation, and non-streaming chat require a non-empty final answer and
`finish_reason: "stop"` from the OpenAI-compatible provider. Responses marked
`length`, filtered/tool-call responses, missing completion markers, and
reasoning-only output are rejected. Only leading, unfenced `<think>` blocks are
treated as model reasoning and removed before validating the final text. Tags
inside final text or code examples are preserved. A literal tag block at the very
start of a response must be fenced to distinguish it from reasoning.
Rejected OCR or translation output is not saved as completed text.

If processing reports incomplete output, use a model with a larger output budget
or split the page into smaller sections, then reprocess. Ensure the provider
returns the completion marker. The client does not automatically increase token
limits or segment pages; existing background job retries may still run.
Streaming chat uses a separate completion path and is not covered by this validation.
