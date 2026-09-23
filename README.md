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
in development mode with source files mounted for hot reload; for a deployment rather than a
development environment, use `docker-compose.runtime.yml` instead — see
[Runtime deployment](#runtime-deployment).

## Runtime deployment

There are two Compose files and they are not interchangeable.

`docker-compose.yml` with `Dockerfile.dev` is **development**. It bind-mounts your working tree, runs
the Mix development server with hot reload, and keeps what it writes inside the repository — the
storage root under `priv/static/uploads`, the database in a Compose volume. That is convenient and it
is disposable: data that lives inside the build output is discarded by a version bump, a
`mix release --overwrite`, or a rebuilt image.

`docker-compose.runtime.yml` with `Dockerfile` is the **optional runtime deployment**. It builds a
compiled `mix release` in a multi-stage build on a digest-pinned Debian base image, runs it as a
non-root user with no source mounted, keeps the database and the storage root
(`DOCTRANS_DATA_DIR=/var/lib/doctrans`) in named Docker volumes that survive an image rebuild, and
runs `/app/bin/migrate` before `/app/bin/server` so a restarted deployment is migrated before it
serves a request.

A release refuses to start without `SECRET_KEY_BASE`. Generate one and keep it — changing it
invalidates every signed cookie and LiveView session:

```bash
mix phx.gen.secret    # or, on a host without Elixir: openssl rand -base64 48
```

Compose reads `.env` from the project directory for variable substitution, so either put the value
there or export it in the environment you run Compose from. The release image mounts no source, so
that file is read by Compose rather than by the application's own `.env` loader. Then build and
start:

```bash
docker compose -f docker-compose.runtime.yml up --build -d
```

Afterwards the data lives in the named volumes rather than in the repository. Both are named
explicitly in the Compose file rather than left to its `<project>_<key>` prefixing, so `docker volume
ls` shows them under exactly the names you back up with: `doctrans_runtime_data` for the storage root
and `doctrans_runtime_pgdata` for the database. The file also sets `name: doctrans-runtime`, so this
stack cannot be confused with the development one, which would otherwise share the project name the
directory implies. An image rebuild keeps both volumes and `docker compose down -v` deletes them,
which is the one command between you and an unrecoverable library — see
[Backup and restore](#backup-and-restore).

Both files publish on host loopback only, for the reason stated at the top of this README: Doctrans
has no authentication, so anything that can reach the port can read every document. The runtime
container binds every interface *inside itself* and lets the published `127.0.0.1:4000` do the
limiting (its database is published on 5433, so it does not collide with the development stack's
5432), which makes republishing that port on another address the one deliberate act that exposes the
application to a LAN — at your own risk. On a native run, `PHX_BIND_IP` is that same decision.

Set `PHX_HOST` to whatever the browser types. Phoenix compares the websocket handshake's `Origin`
host against it, so a deployment reached by a name it does not advertise renders once and then never
connects. Behind a TLS terminator, also set `PHX_SCHEME=https`, which is what the application
advertises as its own address rather than what it listens on.

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

### Processing and indexing status

A document reports two pipelines separately, because they fail separately. **Translation** says whether the
document is queued, running, retrying a page the job queue has scheduled again, failed, stopped or finished,
and names the pages that failed. **Indexing** says how many of the extracted pages have been embedded: a
document can be fully translated and not yet searchable, and a page whose embedding failed counts as
outstanding rather than as indexed.

Three targeted recovery actions appear only when they apply:

- **Retry indexing** re-queues embedding for the extracted pages that are not indexed. It reruns neither
  extraction nor translation, and only chunks still missing a vector are re-embedded, so recovering an
  indexing failure costs nothing that the successful translation already paid for. It is also the only way
  back for a page whose indexing was given up on -- startup recovery reads that as the revision's verdict and
  deliberately will not re-queue it.
- **Retry failed pages** resets and re-queues only the pages that failed, in one pass, leaving successful
  pages and their translations untouched.
- **Stop processing** cancels the document's queued work without deleting anything. Translated pages are
  kept, the document is marked *Stopped*, and it can afterwards be reprocessed as a whole or page by page. A
  job already running is out of the queue's reach and finishes on its own; the stopped state is what keeps
  that straggler from reporting the document complete.

### Search

Use the search input on the dashboard to find content across all documents. Search combines
semantic similarity (AI embeddings) with keyword matching. Press Enter to see results, then
click a result to jump directly to that page.

A page is only offered as a semantic match when it is actually close to the query, so a search for
something your library does not cover comes back empty instead of returning the nearest few hundred
pages in rank order. Keyword matches are never filtered this way: a page that contains your search
term is always a result, however far its meaning sits from the query.

When the embedding server is unavailable, search keeps working on keyword matches alone and the
results page says so, so an outage reads as reduced recall rather than as an empty library.
Semantic matches return once inference is reachable again.

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

Chunks are bounded in size whatever the source looks like. A paragraph longer than the target is
split at sentence boundaries, a sentence longer than the limit at word boundaries, and text that
writes no spaces at all -- Chinese, Japanese, Thai -- at character boundaries. The bound is on
words, characters and bytes together, so a page of emoji is held to the same size as a page of
prose. Documents chunked before this was true keep their existing oversized chunks until the page
is reprocessed or `mix rechunk_documents` is run.

If every retrieval query fails -- an unreachable embedding server, say -- chat reports that
document search is unavailable instead of answering as though the document held nothing relevant.

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
  timeout: 300_000,           # One receive; a server that keeps sending resets it
  deadline: 600_000,          # The whole call, retries included
  max_response_bytes: 8_000_000

# Embedding settings
config :doctrans, :embedding,
  base_url: nil, # Falls back to the OpenAI base_url
  api_key: nil,
  model: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
  timeout: 60_000
  # :deadline and :max_response_bytes fall back to the :openai settings

# Circuit breaker configuration for resilience
config :doctrans, :circuit_breakers,
  openai_api: [strategy: {:standard, 5, 60_000}, refresh: 30_000],
  embedding_api: [strategy: {:standard, 3, 30_000}, refresh: 15_000]

# Retry configuration for exponential backoff
config :doctrans, :retry,
  max_attempts: 3,
  base_delay_ms: 2_000,
  max_delay_ms: 30_000

# Upload settings. The storage root is deliberately absent: it resolves at
# runtime to priv/static/uploads of the running application, and
# DOCTRANS_DATA_DIR replaces it.
config :doctrans, :uploads, max_file_size: 100_000_000  # 100MB

# PDF extraction configuration
config :doctrans, :pdf_extraction, dpi: 150

# Document conversion timeout (for DOCX, DOC, ODT, RTF via LibreOffice)
config :doctrans, :document_conversion, timeout: 120_000

# Default language settings. :target_language preselects the target picker.
# :source_language is only the fallback recorded when detection cannot identify
# a document's language -- the source picker starts on "Detect automatically".
config :doctrans, :defaults,
  source_language: "de",
  target_language: "en"
```

`:timeout` bounds one receive, so on its own it bounds silence rather than the request: an
endpoint that drips a byte at a time resets it forever, and each retry pays it again. `:deadline`
is the wall clock for the whole call, retries included, and `:max_response_bytes` is refused at
the chunk that crosses it rather than after the body is buffered. A page that hits either bound
fails with a message naming the endpoint, and the finished pages around it are kept.

Each document carries its own source and target language, so uploads in different languages
process correctly alongside each other.

The **target** language is chosen in the upload dialog and starts on `target_language` (`en`).

The **source** language is normally detected. The dialog's source picker starts on *Detect
automatically*, and the language is read from the document's own text during processing, then
written to the document. Picking a real language instead pins it and skips detection, which is
the escape hatch for the occasional document detection gets wrong.

Detection runs **once per document** and the answer is stored. Every page translation then reads
the stored value, so a retry or reprocess months later translates from the same language as the
first attempt rather than re-deciding — and it does not follow a later change to the
configuration. `source_language` (`de`) is no longer a default choice: it is only the fallback
recorded when detection cannot tell, so a document always ends up with one stated source language
rather than a silent gap.

Documents that predate this were migrated to the `source_language` configured when the migration
ran, which is the language they were in fact translated from — that history is recorded rather
than re-detected, since it is what produced the text they already contain.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_HOST` | `http://localhost:8000` | Shared API base URL, without `/v1` or a trailing slash |
| `OPENAI_API_KEY` | unset | Bearer API key for both AI and embedding requests |
| `DOCTRANS_ENV_FILE` | `.env` | Environment file path, relative to the working directory or absolute |
| `DOCTRANS_DATA_DIR` | `priv/static/uploads` of the running application | Storage root for originals, converted PDFs, and generated page images. Must be an absolute path; created at startup and must be writable. See [Storage root](#storage-root) |
| `DATABASE_HOST` | `localhost` | PostgreSQL hostname (dev/test) |
| `DATABASE_URL` | - | Full database URL (required in production) |
| `PORT` | `4000` | Phoenix server port (dev/prod; tests use 4002) |
| `PHX_BIND_IP` | `127.0.0.1` | Interface the production endpoint binds to (prod only). Must be an IPv4 or IPv6 address literal; host names are not resolved, and an unparseable value raises at startup naming the variable. Doctrans has no authentication, so it defaults to loopback; set `PHX_BIND_IP=0.0.0.0` to expose it to a trusted LAN at your own risk |
| `PHX_HOST` | `example.com` | Production host for URL generation (dev uses `localhost`). Must be the host the browser actually uses: Phoenix compares the LiveView socket's `Origin` host against it, so a mismatch renders the page once and then never connects |
| `PHX_SCHEME` | `http` | Scheme the application advertises in generated URLs (prod only); use `https` behind a TLS terminator, which also advertises port 443 instead of `PORT`. The application itself always serves plain HTTP on `PORT`. Only the host is origin-checked, so this affects the addresses the app hands out, not whether the socket connects |
| `PHX_SERVER` | unset | Set to `true` to enable the HTTP server when starting a release |
| `SECRET_KEY_BASE` | - | Secret key for signing (required in production) |
| `POOL_SIZE` | `10` | Production database connection pool size |
| `ECTO_IPV6` | unset | Enable IPv6 database sockets in production with `true` or `1` |
| `DNS_CLUSTER_QUERY` | unset | Optional DNS cluster discovery query in production |

### Storage root

Originals, converted PDFs, and generated page images all live under one root,
and page images are served from that same root — moving it moves both writing
and serving.

Unset, the root is `priv/static/uploads` inside the running application. That is
fine for development, but it is *inside the build output*: a release stores data
under `lib/doctrans-<version>/priv`, which a version bump, `mix release
--overwrite`, or a rebuilt container image discards. **Set `DOCTRANS_DATA_DIR`
to a path outside the release for any deployment you intend to keep.**

```bash
DOCTRANS_DATA_DIR=/var/lib/doctrans
```

The path must be absolute — a relative value is rejected at startup rather than
resolved against whatever directory the release happened to start in. The
directory is created at startup if missing, and the application refuses to boot
if it cannot be created or written. It must also sit outside the application's
`priv/static`, since directories served as static assets would hand out your
original documents over HTTP.

**Moving an existing root.** Nothing is migrated for you: the database keeps
rows for documents whose files are no longer where the application looks, so
page images 404 and originals become unreachable. Page paths are stored relative
to the root, so copying the files across is sufficient:

```bash
# stop the application first
mkdir -p /var/lib/doctrans
cp -a priv/static/uploads/. /var/lib/doctrans/
DOCTRANS_DATA_DIR=/var/lib/doctrans mix phx.server
```

## Backup and restore

Two things hold state, and a backup that carries only one of them is not a backup.

**The database** holds the documents and pages — including the extracted and translated Markdown,
which is model output that nothing on disk reproduces — the chunks and embeddings behind search and
chat, the saved conversations (`chat_sessions` and `messages`, with the retrieved context each answer
was given), the processing-run bookkeeping, the Oban job queue, and `schema_migrations`.
Conversations exist only here; there is no file on disk to copy for them.

**The storage root** holds `documents/<id>/original.<ext>`, the retained upload, which is the only
copy of your file the application keeps, and the generated page images under
`documents/<id>/runs/<run-id>/pages/page-NN.png` (documents processed before runs existed keep theirs
in `documents/<id>/pages/`). Where that root is, and why it should not be left at its default for
anything you intend to keep, is covered above under [Storage root](#storage-root).

Only the chunks and embeddings are cheap enough to rebuild rather than carry: `mix rechunk_documents`
rebuilds them across the library and **Retry indexing** does one document, both at the cost of
re-running the embedding model. Page images are *technically* derivable from the retained original,
but only by reprocessing, which deletes every page row and re-runs extraction and translation — the
Markdown goes with them. Back the page images up; they are data, not a cache.

### Taking a backup

`pg_dump` and a file copy are two snapshots taken at two different moments, so they cannot be made
atomic while the application is running. Stopping it first is the honest advice: a stopped
application writes nothing, and the two halves then describe the same instant.

When it cannot be stopped, **dump the database first and copy the files second**. The two failure
modes are not symmetric. A file with no row is an orphan: `Doctrans.Documents.Sweeper` reclaims it
once it is past the grace period, and nothing is broken in the meantime. A row whose file was never
copied is a dangling reference that nothing can repair — the page image 404s, and the retained
original, being the only copy of the upload, is simply gone. Dumping first can only produce the
recoverable kind.

Run `mix verify_restore` after restoring, and also against the live system before taking a backup: it
reports the storage root it checked, how many documents and pages it examined, every row whose
retained source or page images are missing, and every entry under `documents/` that no row owns. It
reports and never repairs, and only the missing direction fails it — an unowned file is what the
sweeper is for. A backup taken from an installation that is already missing files restores exactly
that.

The runtime deployment carries no Mix, so the same check ships in the release as `bin/verify_restore`
— which is the deployment that needs it most, since its state is in volumes rather than in a
directory you can look at:

```bash
docker compose -f docker-compose.runtime.yml exec app /app/bin/verify_restore
```

**Development Compose.** PostgreSQL runs in a container and the host needs no client tools of its own
— the `pgvector/pgvector:pg18` image ships `pg_dump` 18.1. The storage root sits in the working tree,
because the source mount puts it there.

```bash
docker compose exec -T db pg_dump -U postgres -Fc doctrans_dev > doctrans.dump
tar -czf doctrans-data.tar.gz -C priv/static uploads
```

Restoring is the same two steps with the application stopped, into a freshly created database:

```bash
docker compose stop app
docker compose exec -T db dropdb -U postgres --if-exists doctrans_dev
docker compose exec -T db createdb -U postgres doctrans_dev
docker compose exec -T db pg_restore -U postgres -d doctrans_dev < doctrans.dump
tar -xzf doctrans-data.tar.gz -C priv/static
docker compose start app
```

**Runtime deployment.** It keeps its state in the `doctrans_prod` database and in two volumes named
explicitly rather than derived from the project — `doctrans_runtime_data` for the storage root and
`doctrans_runtime_pgdata` for the database — so that the name you back up is the name `docker volume
ls` prints, and so the development stack's `doctrans_pgdata` cannot be mistaken for either. The
storage root is a volume rather than a host directory, so it has to be copied out of the volume:

```bash
docker compose -f docker-compose.runtime.yml exec -T db pg_dump -U postgres -Fc doctrans_prod > doctrans.dump
docker run --rm -v doctrans_runtime_data:/data -v "$PWD":/backup alpine \
  tar -czf /backup/doctrans-data.tar.gz -C /data .
```

Restoring the files is the same throwaway container with the arguments reversed, while the
application container is stopped:

```bash
docker run --rm -v doctrans_runtime_data:/data -v "$PWD":/backup alpine \
  tar -xzf /backup/doctrans-data.tar.gz -C /data
```

**A native run.** The storage root is an ordinary directory, so `cp -a` is enough:

```bash
pg_dump -U postgres -Fc doctrans_dev > doctrans.dump
cp -a /var/lib/doctrans/. /backups/doctrans-data/
```

**Not a backup: the database volume.** Both Compose files mount the database volume (`pgdata`,
`doctrans_pgdata`) at `/var/lib/postgresql`, which is the live data directory with no WAL archiving
or snapshot coordination configured around it. Tarring it while PostgreSQL is running copies a torn
data directory that may refuse to start, or start with data missing. Dump the database instead, or
stop the container and copy it then.

**Version skew.** CI runs PostgreSQL 17 while Compose runs 18. `pg_restore` will not read an archive
produced by a newer `pg_dump` than itself, so a dump taken from 18 does not go back into 17 — restore
into the same major version or a newer one.

### Restoring

**Restore the database before the restored application's first boot.** Two mechanisms begin deleting
files shortly after startup, and both treat the database as the authority on what should exist:

- `Doctrans.Documents.Sweeper` deletes every `documents/<uuid>` directory that has no matching row and
  whose modification time is older than the grace period (24 hours by default, configured under
  `config :doctrans, Doctrans.Documents.SweeperWorker` in `config/config.exs`), and `SweeperWorker`
  runs its first sweep one minute after boot. A restored tree keeps its original timestamps — `cp -a`
  and `tar` both preserve them — so it is already past the grace period the moment it lands. Booting
  against an empty or stale database therefore destroys the retained originals within a minute. If
  the database will not be ready in time, set that `enabled: false` before the boot rather than
  racing it.
- Startup recovery re-queues interrupted work about five seconds after boot, and `RunCleanupJob` —
  which the restored Oban queue may still be holding — deletes the run directories that disagree with
  the `processing_run_id` in the restored row. A database snapshot *older* than the file tree
  therefore removes the page images of the run the files actually describe.

The target PostgreSQL must have pgvector available (both Compose files use `pgvector/pgvector:pg18`).
The dump carries the extension, the `get_fts_config` function and the search-vector trigger, the
trigger that invalidates page embeddings when content changes, and the HNSW index definitions, which
PostgreSQL rebuilds during the restore — on a large library that is the slow part, and it needs no
intervention.

Then run `mix verify_restore` (or `bin/verify_restore` in the release) and open a document. A restore
is good when a document can be viewed, searched, chatted with, and reprocessed from its retained
source.

**Restoring into a different storage root.** Supported, and unremarkable: page paths are stored
relative to the root, so unpacking the tree in a new location and pointing `DOCTRANS_DATA_DIR` at it
is the whole procedure — nothing in the database is rewritten. The constraints on the new location,
and the copy itself, are the same as for moving an existing root under
[Storage root](#storage-root).

## Development

```bash
mix assets.build      # Build the CSS and JS bundles (mix setup does this; mix test needs them)
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

Hooks run automatically on commit, selected by the changed file types.

The gate is defined once, in [`.pre-commit-config.yaml`](.pre-commit-config.yaml), and that file is
the single source of truth for which checks run — `mix precommit` and CI both run exactly those
hooks. It is not restated here, because a second copy drifts. Broadly it covers file and format
validation, translation completeness, compilation with warnings as errors, static and security
analysis, asset bundle builds, type checking, and the test suite with coverage. Read the config for
the current set; each hook carries a comment explaining why it blocks.

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
- Asset toolchain install (`mix assets.setup`) and bundle build (esbuild, Tailwind)
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
