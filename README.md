# Doctrans

A Phoenix LiveView application for translating PDF documents using local AI models via Ollama. Upload a PDF, and Doctrans will extract each page as an image, use a vision model to extract text as Markdown, and then translate it to your target language.

## Features

- PDF upload with automatic page extraction
- Background processing pipeline (image extraction → OCR → translation)
- Split-screen document viewer (original page image | translated markdown)
- Real-time progress updates via WebSocket
- Progressive loading - view completed pages while processing continues
- **Hybrid search** - semantic + keyword search across all pages
- **Sorting** - sort documents by date or name

## Prerequisites

### System Dependencies

1. **Erlang** 27.0 or later
2. **Elixir** 1.18 or later
3. **Node.js** 18 or later (for asset compilation)
4. **PostgreSQL** 14 or later

5. **poppler-utils** - Required for PDF page extraction (`pdftoppm` command)

   ```bash
   # macOS
   brew install poppler

   # Ubuntu/Debian
   sudo apt-get install poppler-utils

   # Fedora
   sudo dnf install poppler-utils
   ```

   Verify installation:
   ```bash
   pdftoppm -v
   ```

6. **Ollama** - Local AI model server for running LLMs

   ```bash
   # macOS
   brew install ollama

   # Linux
   curl -fsSL https://ollama.com/install.sh | sh

   # Or download from https://ollama.ai
   ```

### Ollama Models

Pull the required models before starting:

```bash
# Vision model for OCR/text extraction from page images
ollama pull qwen3-vl:8b

# Text model for translation
ollama pull ministral-3:14b

# Embedding model for semantic search
ollama pull qwen3-embedding:0.6b
```

**Important:** Make sure Ollama is running before starting Doctrans:

```bash
ollama serve
```

You can verify the models are available:
```bash
ollama list
```

## Getting Started

1. **Clone the repository**

   ```bash
   git clone https://github.com/sapientpants/doctrans.git
   cd doctrans
   ```

2. **Install dependencies**

   ```bash
   mix setup
   ```

3. **Start the Phoenix server**

   ```bash
   mix phx.server
   ```

4. **Visit the application**

   Open [http://localhost:4000](http://localhost:4000) in your browser.

## Configuration

Configuration options can be set in `config/config.exs` or via environment variables in `config/runtime.exs`:

### Ollama Settings

```elixir
config :doctrans, :ollama,
  base_url: "http://localhost:11434",
  vision_model: "qwen3-vl:8b",
  text_model: "ministral-3:14b",
  timeout: 300_000  # 5 minutes
```

### Upload Settings

```elixir
config :doctrans, :uploads,
  upload_dir: Path.expand("../priv/static/uploads", __DIR__),
  max_file_size: 100_000_000  # 100MB
```

### Default Language

```elixir
config :doctrans, :defaults,
  target_language: "en"   # English
```

### Embedding Settings

```elixir
config :doctrans, :embedding,
  base_url: "http://localhost:11434",
  model: "qwen3-embedding:0.6b",
  timeout: 60_000
```

## Search and Sorting

### Hybrid Search

The dashboard includes a search feature that combines:
- **Semantic search** - finds pages with similar meaning using AI embeddings
- **Keyword search** - traditional text matching

Search results link directly to the matching page within a document. Type in the search box and results will appear as you type.

### Sorting

Documents can be sorted by:
- **Date uploaded** - newest or oldest first (default: newest)
- **Name** - alphabetical A-Z or Z-A

Use the Sort dropdown next to the search box to change the sort order.

### Backfilling Embeddings

If you have existing documents that were created before enabling search, you can generate embeddings for them:

```bash
mix backfill_embeddings
```

## Usage

1. Click **Upload Document** on the dashboard
2. Drag and drop a PDF or click to browse
3. Enter a title (auto-filled from filename)
4. Select target language (source language is auto-detected)
5. Click **Start Translation**

The document will appear on the dashboard with a progress indicator. Click on it to view completed pages in the split-screen viewer while processing continues in the background.

## Development

```bash
# Run tests
mix test

# Run precommit checks (compile, format, test)
mix precommit

# Start interactive console
iex -S mix phx.server
```

## License

MIT
