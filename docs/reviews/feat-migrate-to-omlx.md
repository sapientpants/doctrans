# Code review: `feat/migrate-to-omlx`

Branch: `feat/migrate-to-omlx` (commit `b5215a8` `feat: migrate to Ollama-compatible API client`)
Scope: migration of the LLM/embedding client from the Ollama API
(`lib/doctrans/processing/ollama.ex`, 594 lines) to an OpenAI-compatible client
(`lib/doctrans/processing/openai.ex`, 490 lines) targeting OMLX
(`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`), plus renames across
`config/`, `lib/doctrans/chat/`, `lib/doctrans/resilience/`,
`lib/doctrans/search/`, `lib/doctrans_web/`, tests, and Docker/README docs.

**Verdict:** the migration is structurally sound, but the branch as committed
did not build (8 blocking defects, one of them a 100%-CPU hang of the entire
test suite). All 8 are fixed in the current working tree; `mix precommit` is
green and the full suite passes 531/531. Section 2 lists 15 remaining findings,
the most important being an API-key prefix leak in logs (R1), fake streaming
(R2), and inert POST retries (R3).

---

## 1. Blocking defects — fixed in this review

| # | Severity | Defect | Fix |
|---|----------|--------|-----|
| F1 | **P0** | Test-suite-wide hang / CPU spin from a self-referential Mox stub | Module renamed; 3 files (below) |
| F2 | P1 | `strip_code_fences/1` undefined — 8 tests in `openai_test.exs` crashed with `UndefinedFunctionError` | Restored + wired into all response paths |
| F3 | P1 | `chat_stream` used `into: "text/event-stream"` — Req only accepts `nil \| fun \| :self \| :legacy_self \| collectable`; a bare string falls into the collectable branch and raises `Collectable.into/1` on every 200 response | Removed (verified in `deps/req/lib/req/finch.ex:263-335`) |
| F4 | P1 | `parse_embed_response/1` had a second clause matching the same shape and recursing into itself — infinite recursion on the happy path | Removed; catch-all handles invalid bodies |
| F5 | P1 | `embed/2` could resolve `model = nil` (only read caller opts) | `Keyword.get(opts, :model) \|\| embed_config()[:model] \|\| model(opts)` |
| F6 | P1 | Stub used `:erlang.random(-1.0, 1.0)` (undefined in Elixir) and `@impl true` on `embed/2` (behaviour has no `embed` callback) | `:rand.uniform() * 2 - 1`; `@impl` removed |
| F7 | P1 | `Sandbox.mode(Repo, :shared)` — pre-existing on `main` but blocks `mix precommit`: Ecto 3.14's `mode/2` typespec/guards are `:auto \| :manual \| {:shared, pid()}`; a bare `:shared` is both a type warning **and** a runtime `FunctionClauseError` (verified with a direct call) | `{:shared, self()}` in `test/support/data_case.ex:37` and `test/support/worker_helpers.ex:17` — the documented form, and a safe no-op since `start_owner!(shared: true)` already shares for `async: false` cases |
| F8 | P1 | `credo --strict` (`.credo.exs` sets `strict: true`) failed on 17 branch-introduced issues | All fixed (below) |

### F1 — self-referential Mox stub (the hang)

`test/support/openai_stub.ex` declared `defmodule Doctrans.Processing.OpenAIMock`
— the *same name* `defmock(Doctrans.Processing.OpenAIMock)` redefines in
`test_helper.exs`, so `Mox.stub_with(OpenAIMock, OpenAIMock)` pointed the mock's
dispatch at itself. Every stubbed call entered a mutual worker↔Mox.Server
tail-call loop compiled with OTP 29's marker-receive optimization
(`:erts_internal.await_result/1`): a flat, never-growing BIF-level spin at
100% CPU. Measured: worker 322M and Mox.Server 319M reductions in 10s;
`:erlang.trace` showed 0 call events (pure BIF spin); the 30s Mox timeout can
never break a tail-call loop. Definitive A/B: `stub_with(OpenAIMock,
OpenAIMock)` → hang; `stub_with(OpenAIMock, <distinct stub module>)` → worker
done in <1s.

**Fix:** stub module renamed to `Doctrans.Processing.OpenAIStub`
(`test/support/openai_stub.ex`); `test/test_helper.exs:14` now
`Mox.stub_with(OpenAIMock, OpenAIStub)`; `config/test.exs` `:openai_module` now
points directly at `OpenAIStub` (matching `main`'s `:ollama_module →
OllamaStub` pattern). `llm_processor_test` went from hanging 60s to 9/9 in 0.1s.

### F8 — Credo `--strict` failures (all 17 introduced by the branch; `main` is clean)

- `lib/doctrans/application.ex`: `load_dotenv/0` added ABC 59/complexity 15 and
  pushed module dependencies to 23 (> 20). Extracted to a new
  `lib/doctrans/env_loader.ex` (`Doctrans.EnvLoader.load/0`, behavior-identical);
  `application.ex` back to 18 deps.
- `lib/doctrans/processing/openai.ex`: `extract_markdown` nesting depth 4 (> 3)
  → restructured into shared `post_chat_completion/2` +
  `resolve_extract_response/2` / `resolve_chat_response/2` (also removes the
  duplicated `Req.post` block); two single-item list appends
  (`opts ++ [messages: …]`) → `Keyword.put/3`; 13 parenthesized no-arg defs →
  unparenthesized; explicit `try do` → `rescue` directly in `def` (per
  `Credo.Check.Readability.PreferImplicitTry`).
- `test/support/openai_stub.ex`: 2 parenthesized no-arg defs.
- `mix credo` now reports **no issues**; `mix format` clean; `mix compile
  --all-warnings --warning-as-errors` clean for all envs.

---

## 2. Remaining findings (not fixed — recommend follow-ups)

| # | Sev | Location | Finding | Suggested fix |
|---|-----|----------|---------|---------------|
| R1 | **P1 security** | `lib/doctrans/search/embedding.ex:48` | Debug log prints the first 10 chars of the API key (`api_key: #{String.slice(api_key, 0, 10)}...`). Violates the project rule against logging secrets; a 10-char prefix meaningfully narrows the keyspace of a short key. | Log `api_key: <set>` / `<none>` only. |
| R2 | P1 | `lib/doctrans/processing/openai.ex:214-235` | `chat_stream/3` is not streaming: `on_delta` is never invoked (`collect_streamed_content/3` takes `_on_delta`), the whole response is buffered and parsed in one pass, and the request has no `retry:` option. Chat UIs expecting incremental updates get a silent no-op until the full body arrives. | Either implement real SSE consumption (Req stream/collectable + per-chunk `on_delta.`) or drop the `on_delta` parameter and document it as non-streaming. |
| R3 | P1 | `openai.ex` (all `retry: :safe_transient` sites: `chat`, `extract_markdown`, `embed`, `chat_stream`) | Req's `:safe_transient` preset retries **only safe (GET/HEAD)** requests (`deps/req/lib/req/steps.ex:1672,1680`). All of these are `Req.post`, so transient 5xx/connection errors on LLM calls are never retried. Only `list_models` (GET) actually retries. | Use `retry: :transient` for the POSTs (chat-completion/embed POSTs are idempotent for this use case) or pass an explicit retry count/policy. |
| R4 | P2 | `openai.ex:~478 handle_api_error/2` | Melts the `:openai_api`/`:embedding_api` fuse on **every** error, including permanent 4xx (bad model name, 401). One bad config melts the breaker (5 failures / 60s) and black-holes all subsequent LLM calls until the half-open probe. | Classify via `Doctrans.Resilience.ErrorClassifier` first; melt only for `:retryable`-class transport/5xx errors, return permanent errors untouched. |
| R5 | P2 | `lib/doctrans/chat/grader.ex:85`, `lib/doctrans/chat/query_expander.ex:148` | Branch deleted `@grade_timeout 30_000` / `@expansion_timeout 30_000` and stopped passing `:timeout`, so these structured calls inherit the client's 300s default. A wedged model blocks chat for 5 min instead of the intended 30s budget. | Restore `:timeout` in both `chat_opts/1` base lists. |
| R6 | P2 | `lib/doctrans/processing/openai.ex` `default_model/0` | `main` defaulted extraction to `vision_model` and translation to `translation_model` (`main:ollama.ex:39,120`); the new client defaults **both** to the `chat_model` or `vision_model` fallback. With current config, extraction silently switches from the 9B vision model to the 35B chat model. | Extraction should default to `vision_model`; translation to `translation_model`. |
| R7 | P2 | `config/config.exs` `:openai` / `:embedding` | `main` was env-first (`System.get_env("OLLAMA_HOST", "http://localhost:11434")`); the branch hardcodes `"http://localhost:8000"` and relies on `EnvLoader` overwriting app env at boot. Works via `.env`, but a stale `.env` clobbers real environment (see R8), and config is no longer inspectable without boot. | `base_url: System.get_env("OPENAI_HOST", "http://localhost:8000")`, keep `api_key: System.get_env("OPENAI_API_KEY")`. |
| R8 | P2 | `lib/doctrans/env_loader.ex` (extracted from `application.ex` by this review) | `System.put_env/2` is unconditional: values from `.env` override *real* environment variables, inverting dotenv convention (real env should win). Also applies the same `OPENAI_API_KEY`/`OPENAI_HOST` to both `:openai` and `:embedding` (fine for a single OMLX endpoint, but worth documenting). | `unless System.get_env(key), do: System.put_env(key, value)`. |
| R9 | P3 | `.env.gpg` (368 B, added by branch) | Encrypted secret committed to the repo. Acceptable only with a clear key-distribution/rotation story; otherwise remove and keep `.env.example` as the only committed env artifact. | Document key handling in README or drop from the branch. |
| R10 | P3 | `openai.ex:349 embed/2` vs `lib/doctrans/search/embedding.ex` | `OpenAI.embed/2` is dead code — nothing calls it. The real embedding path (`Search.Embedding`) makes its own raw `Req.post` with no circuit-breaker, no retry, and the key-leak log (R1), so the `:embedding_api` fuse in config is never actually melted. | Have `Search.Embedding` delegate to `OpenAI.embed/2`, or move fuse/retry into `Search.Embedding`. |
| R11 | P3 | `test/support/openai_stub.ex:54-62` | `list_models` stub: the non-nil branch of `:openai_stub_models` returns `{:error, value}`, so the env var can only stub *errors*, never a custom model list (latent — no test sets it today). | Split into `:openai_stub_models` / `:openai_stub_models_error`, or type-check the value. |
| R12 | P3 | `openai.ex:~145-195 parse_chat_response/1` | Three overlapping clauses: the `map_size(message) == 0` guard can only fire for an empty map (then `check_for_reasoning`/`"Empty or missing response"`), and the `finish_reason: "length"` clause largely duplicates it. Works, but hard to reason about for the empty-response regression it guards. | Collapse into: content present → ok; else inspect `reasoning`/`reasoning_content`; else error. |
| R13 | info | `lib/doctrans/resilience/error_classifier.ex` | Branch removed `:timeout` / `:enoent` / `:eacces` from the *generic* atom clause — but dedicated earlier clauses (`:48-49`, `:68-70`) still map all three, so behavior is byte-identical to `main`. An earlier review pass flagged this as a regression; it is a false alarm (dead-clause cleanup + cosmetic `reason` → `atom_reason` rename). | None. |
| R14 | info | `test` logs | `EmbeddingWorker` background Task crashes with `StaleEntryError` on a chunk a test just deleted (`embedding_worker.ex:139/251`) — pre-existing background-task/teardown race, pre-dates this branch; noisy but non-failing. | Guard the `update!` or tag affected tests `background_processes: true` + shared sandbox. |
| R15 | info | repo root | `erl_crash.dump` (~2 MB, gitignored) left over from the F1 hang investigation. | `rm erl_crash.dump`. |

---

## 3. Verification

- `mix precommit` → **exit 0** (`compile --warning-as-errors --all-warnings`,
  `deps.unlock --unused`, `deps.audit`, `format --check-formatted`,
  `credo --strict` (0 issues), `sobelow --config`, `test`).
- `mix test` → **531 passed, 0 failed** (was: hang at `llm_processor_test`,
  then 523/531 after the F1 fix, 531/531 after F2-F6).
- F1 root cause confirmed by A/B experiment with `REPRO_MODE=self|control`
  (self-referential stub → both processes at 100% CPU, 480M+ reductions/15s;
  distinct stub → success in <1s).
- F7 runtime behavior confirmed: `Sandbox.mode(Repo, :shared)` raises
  `FunctionClauseError` on Ecto 3.14.2/ecto_sql 3.14.0 (guards: `mode in
  [:auto, :manual]` or `{:shared, pid()}`); `{:shared, self()}` returns `:ok`.
  Note: the `background_processes: true` tag passed via `use Doctrans.DataCase,
  …` is silently dropped by `ExUnit.CaseTemplate.__proxy__` →
  `ExUnit.Case.__keys__` (unknown options are not tags), so both `:shared`
  branches are effectively dead code — sandbox sharing for `async: false` tests
  comes from `start_owner!(shared: not tags[:async])`.
- `:safe_transient` POST behavior verified against `deps/req/lib/req/steps.ex:1672-1680`.
- Model-default regression (R6) verified against `main`'s `ollama.ex:39/120/184`.

## Files changed in this review (working tree, uncommitted)

- `lib/doctrans/processing/openai.ex` — F2, F3, F4, F5, F8 (+ F1 consumer)
- `lib/doctrans/env_loader.ex` — **new** (F8; extracted from `application.ex`)
- `lib/doctrans/application.ex` — F8 (delegates to `EnvLoader`)
- `test/support/openai_stub.ex` — F1, F6, F8 (module renamed to `OpenAIStub`)
- `test/test_helper.exs` — F1 (`stub_with(OpenAIMock, OpenAIStub)`)
- `config/test.exs` — F1 (`:openai_module → OpenAIStub`)
- `test/support/data_case.ex`, `test/support/worker_helpers.ex` — F7 (`{:shared, self()}`)
