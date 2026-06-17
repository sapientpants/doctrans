# Provider Refactor Improvement Plan

Addresses all issues from the security & quality review of `feature/unsloth-provider`.

---

## 1. Add `think: false` to Unsloth requests (Security #1)

**File:** `lib/doctrans/processing/unsloth.ex`

**Problem:** Ollama's `extract_markdown` and `translate` set `think: false` to prevent the model from consuming its output budget on chain-of-thought reasoning. The Unsloth module omits this flag.

**Changes:**
- `extract_markdown/2` — add `think: false` to the request body (line ~79)
- `translate/4` — add `think: false` to the request body (line ~126)
- Add the same comment that exists in the Ollama module explaining why

**Verification:** Confirm Unsloth Studio's API accepts the `think` field in both `/api/generate` and `/api/chat` payloads. If it does not, skip and document.

---

## 2. Collapse duplicated behaviour into shared `ProviderBehaviour` (Quality #6)

**File:** `lib/doctrans/processing/provider_behaviour.ex` (new)

**Problem:** `OllamaBehaviour` and `UnslothBehaviour` are identical.

**Changes:**
- Create `Doctrans.Processing.ProviderBehaviour` with the 5 callbacks
- Update `OllamaBehaviour` to delegate: `@callback ...` → `@behaviour ProviderBehaviour` (or remove entirely and have both modules implement `ProviderBehaviour` directly)
- Update `UnslothBehaviour` similarly
- Update `OllamaStub` to implement `ProviderBehaviour`
- Update `test_helper.exs` Mox defmock to use `ProviderBehaviour`

**Verification:** `mix compile --warning-as-errors` passes, all mocks resolve.

---

## 3. Extract shared utilities into `LlmUtils` (Quality #5)

**File:** `lib/doctrans/processing/llm_utils.ex` (new)

**Problem:** `strip_code_fences/1` and `language_name/1` are duplicated across Ollama and Unsloth.

**Changes:**
- Create `Doctrans.Processing.LlmUtils` module
- Move `strip_code_fences/1` and `language_name/1` from both modules into `LlmUtils`
- Import `LlmUtils` in `Ollama` and `Unsloth`
- Remove duplicate definitions

**Verification:** Both providers compile and produce identical output for the same input.

---

## 4. Consider shared provider base (Quality #4)

**File:** `lib/doctrans/processing/provider_base.ex` (new, optional)

**Problem:** Unsloth is a 416-line near-clone of Ollama. Only 3 things differ: module name, config key (`:ollama` vs `:unsloth`), and circuit breaker key (`:ollama_api` vs `:unsloth_api`).

**Approach — macro-based codegen:**
- Create a `Doctrans.Processing.Provider` macro that takes `config_key`, `circuit_key`, and `display_name`
- The macro generates the full module: `extract_markdown`, `translate`, `chat`, `available?`, `list_models`, and all private helpers
- Replace `Ollama.ex` and `Unsloth.ex` with thin wrappers:
  ```elixir
  defmodule Doctrans.Processing.Ollama do
    use Doctrans.Processing.Provider,
      config_key: :ollama,
      circuit_key: :ollama_api,
      display_name: "Ollama"
  end
  ```

**Risk:** This is a larger refactor. If Unsloth's API diverges from Ollama's in the future (different endpoints, payload shapes), the macro approach becomes fragile.

**Recommendation:** Defer this until after the branch is merged. For now, the duplication is acceptable — the DuplicatedCode check is disabled with an explicit comment.

---

## 5. Add Unsloth stub and tests (Quality #7)

**Files:**
- `test/support/unsloth_stub.ex` (new)
- `test/doctrans/processing/unsloth_test.exs` (new)

**Problem:** Unsloth is untested. The test config points `:provider_module` to `OllamaStub`.

**Changes:**
- Create `Doctrans.Processing.UnslothStub` — mirror `OllamaStub` but implement `ProviderBehaviour` (or `UnslothBehaviour` if #2 is deferred)
- Add `Mox.defmock(Doctrans.Processing.UnslothMock, for: ProviderBehaviour)` to `test_helper.exs`
- Create `unsloth_test.exs` with the same test cases as `ollama_test.exs` (request building, response parsing, error handling, empty response detection)

**Verification:** `mix test` passes with both Ollama and Unsloth stubs.

---

## 6. Only check active provider in health check (Quality #8)

**File:** `lib/doctrans/resilience/health_check.ex`

**Problem:** `check_all/0` always checks both Ollama and Unsloth. If the non-active provider is down, `healthy?/0` returns `false` even though the app is functional.

**Changes:**
- Read `:provider_module` from config
- Only include the active provider in `check_all/0` results
- Keep both `check_ollama/0` and `check_unsloth/0` available for manual/status-page use
- Alternative: always check both but mark inactive as `:skipped` instead of `{:error, ...}`

**Verification:** Health check returns `healthy?() == true` when only the active provider is running.

---

## 7. Add provider validation at startup (Security #3)

**File:** `lib/doctrans/search/embedding.ex`

**Problem:** `provider_to_config_key/1` falls back to `:ollama` for unknown modules. A misconfigured `:provider_module` silently routes embeddings to Ollama.

**Changes:**
- On first call to `provider_embedding_config/0`, log a warning if the provider module is unknown
- Or: validate at application startup (in `Doctrans.Application.start/2`) that `:provider_module` is one of the known providers and that its config exists

**Verification:** Setting an unknown provider module produces a startup warning or crash (fail-fast).

---

## 8. Separate circuit breakers per-provider for embeddings (Quality #9)

**File:** `lib/doctrans/search/embedding_worker.ex`, `config/config.exs`

**Problem:** Both providers share the `:embedding_api` circuit breaker. An error spike from one provider trips the circuit for the other.

**Changes:**
- Add `:ollama_embedding_api` and `:unsloth_embedding_api` circuit breakers to config
- In `EmbeddingWorker.embed_chunk/3`, resolve the circuit breaker key from the active provider:
  ```elixir
  circuit_key =
    case provider_module() do
      Doctrans.Processing.Ollama -> :ollama_embedding_api
      Doctrans.Processing.Unsloth -> :unsloth_embedding_api
      _ -> :ollama_embedding_api
    end
  ```
- Update `HealthCheckWorker.maybe_reset_circuits/2` to reset the per-provider embedding circuit on recovery

**Verification:** Circuit for one provider opens independently of the other.

---

## Execution order

| Phase | Issues | Effort | Risk |
|---|---|---|---|
| **Phase 1** (quick wins) | #1, #3, #7 | 30 min | Low |
| **Phase 2** (behaviour cleanup) | #2, #5 | 1 hr | Low |
| **Phase 3** (resilience) | #6, #8 | 1 hr | Low |
| **Phase 4** (refactor, post-merge) | #4 | 2-3 hr | Medium |

Phase 1–3 can be done before merging the branch. Phase 4 is a post-merge refactor.
