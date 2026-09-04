# Doctrans — Code Quality, Maintainability & Security Improvement Plan

A prioritized plan derived from a full review of the codebase (Phoenix 1.8 / LiveView,
Oban, pgvector, MDEx/HtmlSanitizeEx, local OpenAI-compatible MLX inference server). Items are grouped
by priority; each includes the problem, the affected code, and the proposed fix.

---

> **Scope note:** Doctrans is a **local, single-user app** — authentication is **not
> required** (see `AGENTS.md`). Items that previously assumed an exposed, shared
> deployment (auth pipeline, per-request upload authorization) are reframed as
> "bind to loopback by default / firewall the port" deployment guidance instead.

## P0 — Security

### 1. Deployment exposure: endpoint binds all interfaces with no auth

- **Problem:** No authentication is needed for a local app, but the production config
  binds `{0,0,0,0,0,0,0,0}` in `config/runtime.exs`, so the default release is reachable
  from the whole LAN. Since there is no auth, anyone on the network can upload, read,
  chat with, and delete documents, and browse page images under `/uploads`. The session
  cookie is also signed (readable) but not encrypted.
- **Affected:** `config/runtime.exs`, `config/prod.exs`, `docker-compose.yml`.
- **Fix:**
  - Default the prod bind address to loopback (`127.0.0.1`) and make all-interface binding
    opt-in via an env var (e.g. `PHX_BIND_IP=0.0.0.0`), documented as "exposing to a
    trusted LAN at your own risk".
  - Do the same for the Docker setup: publish the port to `127.0.0.1` by default.
  - Add `:encryption_salt` to `@session_options` so the session cookie is encrypted, not
    just signed (defense in depth even for local use).

### 2. LibreOffice conversion can leak zombie processes (DoS vector)

- **Problem:** `DocumentConverter.run_conversion/2` runs `System.cmd("soffice", ...)` in a
  `Task` and on timeout calls `Task.yield(task, timeout) || Task.shutdown(task)`.
  Killing the *task* does not reliably kill the *soffice OS child process* — each timed-out
  upload can leave a headless soffice running, consuming CPU/IO (no auth is needed for a
  local app, but the same machine — including other local users or a rogue document —
  can exhaust it). Additionally, `get_soffice_path/0` falls through to the bare string `"soffice"` even when
  no executable exists, and `available?/0` / `get_soffice_path/0` duplicate path logic.
- **Affected:** `lib/doctrans/processing/document_converter.ex`.
- **Fix:**
  - Run soffice under a supervised process (e.g. `Port`/`open_port` or a `Task` that spawns
    via `Process.spawn` + `System.cmd` in an OS process group) so a timeout can send
    `SIGKILL` to the actual process on timeout/failure.
  - Fail fast (clear error) when the resolved path does not exist instead of calling a
    bare `"soffice"`. Consolidate `available?/0` and `get_soffice_path/0` into one helper.
  - Pass an isolated `-env:UserInstallation=/tmp/...` profile to avoid profile-lock races
    between concurrent conversions and the user's running LibreOffice instance.
  - Add a test covering the timeout path asserting the child is reaped.
  - (Even without auth, a user can trigger this via their own uploads, so the reaping
    fix stands on its own.)

### 3. `.env` loader runs in every environment and *wins* over real env vars

- **Problem:** `Doctrans.EnvLoader.load/1` is called unconditionally in `Application.start/2`
  and its documented behavior is "`.env` file values always win over inherited environment
  variables". In production this means a `.env` file that accidentally ships in a release
  will silently override `OPENAI_HOST` / `OPENAI_API_KEY` from the real environment.
- **Affected:** `lib/doctrans/env_loader.ex`, `lib/doctrans/application.ex`.
- **Fix:** Gate the loader on `Mix.env() != :prod` (or `config_env() in [:dev, :test]`), and/or
  flip precedence so real env vars win over the file. Keep the boot-time re-application of
  `:openai` / `:embedding` config, but only in dev.

### 4. Static serving of document pages

- **Problem:** `Plug.Static` serves `priv/static/uploads` (extracted page images of
  private documents) to any client. UUID7 document ids are hard to guess, which is
  acceptable for a local app, but the page *paths* are visible in DOM `<img>` tags and
  browser history once a document is opened.
- **Fix:** No auth needed (see scope note) — cover this with item 1's loopback-by-default
  binding, and add `cache_control` metadata so page images aren't aggressively cached by
  shared proxies.

### 5. Unbounded growth of accumulated chat retrieval context

- **Problem:** `Doctrans.Chat.Agent` keeps "real retrieved chunks" accumulating across
  conversation turns (`chat_retrieved_context`), with history capped at 16 messages but
  **no cap on the retrieved context itself**. Long conversations send ever-larger prompts:
  slow responses, token-cost blowups, and the context is never pruned on client disconnect
  semantics. It is also all in-memory socket state, so it disappears on reload (fine), but
  grows without limit during a session.
- **Affected:** `lib/doctrans/chat/agent.ex`, `lib/doctrans_web/live/book_live/chat_session.ex`.
- **Fix:** Cap accumulated context by total characters/tokens (e.g. keep most recent N
  chunks or the highest-similarity chunks, trim oldest), and log/drop when the cap trips.
  Add a unit test that verifies the trim behavior.

### 6. Validation module returns hard-coded English error strings

- **Problem:** `Doctrans.Validation` returns raw English strings ("Query too short",
  "Missing required fields: ...") while the rest of the app is gettext-i18n'd (11 locales).
  These strings surface in user-facing flashes, so non-English users see English errors.
- **Affected:** `lib/doctrans/validation.ex`.
- **Fix:** Return error *atoms* (e.g. `:query_too_long`) and map them to
  `dgettext` calls in the UI layer, or add a `use Gettext` backend to the module and emit
  translated messages with bindings.

---

## P1 — Maintainability

### 7. Directory/module mismatch: `book_live/` holds `DocumentLive` modules

- **Problem:** `lib/doctrans_web/live/book_live/` contains modules named
  `DoctransWeb.DocumentLive.*` — a leftover from the Book→Document rename. New contributors
  can't find code by module name, and code generators/aliases will create a *different*
  path (`document_live/`).
- **Fix:** `git mv lib/doctrans_web/live/book_live lib/doctrans_web/live/document_live`
  and rename test files accordingly (module names already correct, so this is a pure
  move + path updates). Do this as a single isolated commit.

### 8. Fragmented, duplicated model/config defaults

- **Problem:** Model names and endpoints are hard-coded in at least four places:
  `config/config.exs` (`:openai` models), `config.exs` `:embedding` base_url
  (`"http://localhost:8000"` duplicated), `show.ex` fallback defaults
  (`"mlx-community/Qwen3.5-9B-MLX-4bit"` etc.), and `config.exs` OpenAI section. The
  `show.ex` fallbacks silently diverge from config when models are updated (this has
  already happened historically per git log).
- **Fix:** Introduce a small `Doctrans.Config` module with typed accessors
  (`OpenAI.vision_model/0`, `OpenAI.chat_model/0`, `Embedding.base_url/0`, `Uploads.max_file_size/0`)
  and replace every `Application.get_env(:doctrans, :openai, [])` / magic-string read
  site with those accessors. Single source of truth, easier to test.

### 9. `show.ex` is a 599-line LiveView with ~25 assigns and 15+ handlers

- **Problem:** `DocumentLive.Show` mixes: page viewer (zoom/pan/prev/next), document search,
  reprocess modal, chat panel, embedding-status polling, PubSub message routing. `ChatSession`
  was extracted (good), but the module remains the largest in the codebase and is the
  hardest to test/maintain.
- **Fix:** Extract at minimum the reprocess-modal (state + handlers + template component)
  and the page-viewer controls into small function-component/behaviour modules following
  the `ChatSession` pattern. Target < 350 lines for `Show`.

### 10. `Documents` context is doing four jobs

- **Problem:** `Doctrans.Documents` mixes CRUD, file-system path helpers, progress
  calculation (including a `calculate_progress/1` fallback that does a DB preload per
  document), and PubSub topics. `list_documents_with_progress/1` shadows `pages` and builds
  structs with `Map.put` instead of a clean "document summary" struct.
- **Fix:**
  - Split into `Documents` (CRUD + file paths), `Documents.Progress` (pure functions on
    page status lists), `Documents.Topics` (PubSub subscribe/broadcast).
  - Replace the manual `%{document | pages: pages}` reconstruction with a dedicated
    summary struct so templates don't depend on ad-hoc map fields.
  - Remove or clearly mark the N+1 `calculate_progress/1` fallback.

### 11. Over-broad `rescue` blocks in `Worker`

- **Problem:** `Worker.status/0` ends with a bare `rescue _ -> %{...zeros}` that masks
  *all* `RuntimeError`s (including real bugs) as "Oban not available". `cancel_document/1`
  likewise rescues and returns `:ok`, hiding failures of cancellation.
- **Fix:** Rescue specifically (`Ecto.NoResultsError` / `Postgrex.Error`), log the real
  reason, and for `cancel_document` return `{:error, reason}` so callers can surface it.

### 12. `cancel_document` uses Postgres-specific fragments tied to JSON arg shape

- **Problem:** `Worker.cancel_document/1` matches jobs via
  `fragment("args->>'document_id' = ?", ...)` — brittle to any key rename in job args and
  unindexed (sequential scan of `oban.jobs` per cancel).
- **Fix:** Include `metadata: %{"document_id" => id, "page_id" => ...}` in job args where
  Oban offers first-class query support, or keep a `doctrans_jobs` metadata column, and
  add an index; at minimum centralize the JSON-key names as module attributes so the job
  definition and the cancel query can't drift.

### 13. Inconsistent error-surface conventions

- **Problem:** Some layers return `{:error, "english string"}`, others `{:error, reason_atom}`,
  others return a failed `Ecto.Changeset`, and LiveViews convert each differently.
  `LlmProcessor`'s moduledoc admits Gettext won't work in background processes — a good
  rationale, but the *conversion* to user-facing text happens in at least three places.
- **Fix:** Standardize: domain modules return `{:error, atom | {atom, bindings}}`; only the
  web layer (LiveView/components) maps to translated strings via one helper
  (`ErrorMessages.message/1`). Document the convention in a short `docs/CONTRIBUTING.md`.

---

## P2 — Quality & Reliability

### 14. LiveView `mount` raises on missing documents → 500 instead of 404

- **Problem:** `DocumentLive.Show.mount/3` calls `Documents.get_document_with_pages!(id)`;
  a bad/already-deleted id raises `Ecto.NoResultsError` and the client gets a 500 page
  (and a logged exception). Also `handle_event("delete_document")` calls `get_document!/1`.
- **Fix:** Use non-bang `get_document`/`get_document_with_pages` in `mount`, render a
  404-ish state (gettext "Document not found" + link home); make delete handler idempotent
  on missing id.

### 15. Add Dialyzer to `mix precommit` (and CI)

- **Problem:** `mix.exs` already configures strict Dialyzer flags (`:error_handling`,
  `:underspecs`, `:unmatched_returns`, `:no_improper_lists`) and a PLT, but neither the
  `precommit` alias nor the GitHub workflow runs it — the strictness is decorative.
  The codebase has partial `@spec`s (e.g. in `index.ex`), so specs will only help if
  enforced.
- **Fix:** Add `"dialyzer"` to the `precommit` alias and to CI (warm the PLT via
  `mix dialyzer --plt` cache step); triage `priv/plts/dialyzer.plt` ignore file. Add
  `@spec` coverage for the public APIs of `Validation`, `Search`, `OpenAI`, `Worker`.

### 16. `@spec consume_upload_entry :: {:ok, term()}` leaks `term()`

- **Problem:** `index.ex` annotates a 4-tuple/2-tuple result as `term()`, defeating
  Dialyzer; the same tuple is then pattern-matched in two different shapes by callers.
- **Fix:** Define an `@type upload_result :: {:ok, document_id, filename, path} |
  {:error, filename, reason}` and use it in the spec + the `split_with` predicate.

### 17. Sobelow config blanket-ignores `Traversal.FileModule`

- **Problem:** `.sobelow-conf` ignores *all* file-traversal findings because "paths are
  constructed from trusted sources". Upload filenames are user-supplied (even after
  `sanitize_filename_string`); even in a local app a malicious document can come from any
  user of the machine, so traversal remains a live bug class and blanket ignores rot.
- **Fix:** Replace the blanket ignore with targeted `ignore: [{:manual, ...}]` per call
  site after auditing each `File.cp`/`Path.join` involving user input; add a test that
  adversarial client filenames (`../../etc/x`, backslashes, nulls, unicode) land inside
  the per-document dir.

### 18. Dashboard re-queries the entire documents table on every coalesced refresh

- **Problem:** `refresh_list` (index) re-runs `list_documents_with_progress` (all documents +
  all lightweight page rows) on every PubSub-coalesced tick; fine for 10 documents, linearly
  painful at 500.
- **Fix:** On document-level events, update the affected stream item in place
  (`stream_insert`/update); on page-level events, update only the card's progress assign
  instead of re-querying everything. Add a `limit`/pagination knob if document counts grow.

### 19. Worker startup recovery re-queues *all* incomplete pages without bounds

- **Problem:** `:recover_incomplete_documents` re-queues every page of every
  "processing" document unbounded on boot. After a crash mid-way through a 5,000-page
  book this floods the `llm_processing` queue and the local LLM.
- **Fix:** Batch the re-queue (e.g. chunk with `Enum.chunk_every` + small delay, or cap per
  boot and schedule the rest via `Oban` `schedule`), and mark recovered jobs so the
  document's progress display stays consistent.

### 20. Session storage for chat is entirely ephemeral — no crash/upgrade survival, no docs

- **Problem:** Chat history + retrieval context live in socket assigns only; a LiveView
  reload silently drops the whole conversation, with no "conversation lost" notice and no
  way for the user to know.
- **Fix:** Minimum: persist chat messages to a `messages` table keyed by document (and a
  `chat_sessions` table) with rotation; at least add a user-visible "conversation resets on
  reload" note and a heartbeat-guarded warning when the socket recovers without history.

---

## P3 — Testing Gaps

### 21. Tests missing for the security-sensitive paths

Current suite is solid (components, LiveViews, processing, search, chat), but the
*adversarial* paths are uncovered:

- Upload: malicious filenames/paths, size-limit boundary, magic-byte mismatch for each of
  the 5 supported extensions (only happy path in `index` tests).
- `MarkdownHelpers.sanitize_html/1`: `<script>`, `onerror=` image payloads, `javascript:`
  hrefs, nested `<iframe>` (XSS via LLM output is the main web risk — MDEx +
  HtmlSanitizeEx is the only defense).
- `DocumentConverter` timeout → zombie process reaping (from item 2).
- `Documents.Sweeper` grace-period behavior with a file being *concurrently served*.
- `Worker.cancel_document` JSON-fragment queries (Postgres only — needs `@tag :postgres` or
  a test doubles path).
- Security (P0): encrypted session cookie (`:encryption_salt`).

### 22. Coverage gate exists (80%) but `mix cover` isn't in precommit/CI

- **Fix:** Add `test --cover` (coveralls) to CI so the 80% floor actually gates merges;
  then drive coverage up in the areas above.

---

## Suggested execution order

| PR | Contents |
|----|----------|
| 1  | #7 rename `book_live/` → `document_live/` (pure move, low risk) |
| 2  | #8 `Doctrans.Config` accessor module + replace magic strings |
| 3  | #1 loopback-by-default bind + #3 env-loader prod gate + #4 upload serving hardening |
| 4  | #2 soffice process reaping + #17 targeted sobelow ignores |
| 5  | #5 chat context cap + #20 conversation persistence |
| 6  | #6 i18n'd validation errors |
| 7  | #13 error-atom convention + #6 i18n'd validation errors |
| 8  | #10 split `Documents` + #9 split `Show` (two refactor PRs if large) |
| 9  | #14 404 handling + #15 dialyzer in precommit/CI + #16 specs |
| 10 | #19 recovery batching + #18 in-place dashboard updates |
| 11 | #21/#22 test additions throughout (can land alongside 3–5) |

Each PR is independently shippable; items marked P0 (1–6) are the priority if scope is
limited. (An auth pipeline was deliberately dropped: Doctrans is a local app — see
`AGENTS.md`.)
