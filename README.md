# Doctrans

A Phoenix LiveView application for translating PDF documents using local AI models via
Ollama. Upload a PDF, and Doctrans will extract each page as an image, use a vision model
to extract text as Markdown, and then translate it to your target language.

## Features

- PDF upload with automatic page extraction
- Background processing pipeline (image extraction → OCR → translation)
- Split-screen document viewer (original page image | translated markdown)
- Real-time progress updates via WebSocket
- Progressive loading - view completed pages while processing continues
- Hybrid search - semantic + keyword search across all pages
- Document sorting by date or name

## Prerequisites

- **Erlang** 27.0+
- **Elixir** 1.18+
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
ollama pull qwen3-vl:8b        # Vision model for OCR
ollama pull ministral-3:14b     # Text model for translation
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
# Ollama settings
config :doctrans, :ollama,
  base_url: "http://localhost:11434",
  vision_model: "qwen3-vl:8b",
  text_model: "ministral-3:14b",
  timeout: 300_000

# Embedding settings
config :doctrans, :embedding,
  model: "qwen3-embedding:0.6b",
  timeout: 60_000

# Upload settings
config :doctrans, :uploads,
  max_file_size: 100_000_000  # 100MB

# Default target language
config :doctrans, :defaults,
  target_language: "en"
```

## Development

```bash
mix test              # Run tests
mix precommit         # Run all checks (compile, format, credo, sobelow, test)
mix credo --strict    # Static code analysis
mix sobelow --config  # Security analysis
mix dialyzer          # Type checking (first run builds PLT)
mix coveralls.html    # Test coverage report
iex -S mix phx.server # Interactive console
```

### Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) for automated git hooks:

```bash
pip install pre-commit
pre-commit install
```

Hooks run automatically on commit, or manually with:

```bash
pre-commit run --all-files
```

### CI/CD

GitHub Actions runs on every push and PR to `main`:

- Pre-commit hooks (formatting, linting, security checks)
- Full test suite with 80% coverage requirement
- Dialyzer type checking
- Uncommitted changes detection

## License

MIT
