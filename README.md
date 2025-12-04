# Doctrans

A Phoenix LiveView application for translating PDF documents using local AI models via Ollama. Upload a PDF, and Doctrans will extract each page as an image, use a vision model to extract text as Markdown, and then translate it to your target language.

## Features

- PDF upload with automatic page extraction
- Background processing pipeline (image extraction → OCR → translation)
- Split-screen document viewer (original page image | translated markdown)
- Real-time progress updates via WebSocket
- Progressive loading - view completed pages while processing continues

## Prerequisites

### System Dependencies

- **Erlang** 27.0 or later
- **Elixir** 1.18 or later
- **PostgreSQL** 14 or later
- **poppler-utils** - For PDF page extraction

  ```bash
  # macOS
  brew install poppler

  # Ubuntu/Debian
  sudo apt-get install poppler-utils

  # Fedora
  sudo dnf install poppler-utils
  ```

- **Ollama** - Local AI model server

  ```bash
  # macOS
  brew install ollama

  # Or download from https://ollama.ai
  ```

### Ollama Models

Pull the required models before starting:

```bash
# Vision model for OCR/text extraction
ollama pull qwen3-vl:8b

# Text model for translation
ollama pull ministral-3:14b
```

Make sure Ollama is running:

```bash
ollama serve
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

### Default Languages

```elixir
config :doctrans, :defaults,
  source_language: "de",  # German
  target_language: "en"   # English
```

## Usage

1. Click **Upload Document** on the dashboard
2. Drag and drop a PDF or click to browse
3. Enter a title (auto-filled from filename)
4. Select source and target languages
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
