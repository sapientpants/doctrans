# TODO: feature/unsloth-provider fixes

## Security (must fix before merge)

- [x] **1. Update Plug and cowlib dependencies** (High)
  - ✅ plug 1.19.1 → 1.19.2
  - ✅ cowlib 2.16.1 → 2.17.1
  - ✅ `mix deps.audit` — no vulnerabilities

- [x] **2. Make ProviderResolver.resolve/1 fault-tolerant** (Medium)
  - ✅ `resolve/0` now returns `{:ok, module}` | `{:error, reason}` tuple
  - ✅ Added `resolve!/0` that raises for explicit crash-at-startup sites
  - ✅ All callers updated to use `resolve!()` (hot paths where crash is desired)

- [x] **3. Downgrade verbose production logging to debug level** (Low-Medium)
  - ✅ Both Ollama and Unsloth: raw response keys → `Logger.debug`
  - ✅ Both Ollama and Unsloth: response length + first 500 chars → `Logger.debug`

- [x] **4. Sanitise inspect/1 in user-facing error strings** (Low)
  - ✅ Replaced `inspect(reason)` with `HttpProvider.format_error/1` in all dgettext calls
  - ✅ Handles exception structs, atoms, binaries, and fallback inspect

## Quality

- [x] **5. Eliminate triple-duplicated behaviour modules** (High)
  - ✅ Deleted `OllamaBehaviour` and `UnslothBehaviour`
  - ✅ Updated `ollama_stub.ex` to use `ProviderBehaviour`

- [x] **6. Extract shared HTTP provider logic** (Medium)
  - ✅ Created `Doctrans.Processing.HttpProvider` with `HttpProvider.Config` struct
  - ✅ Ollama and Unsloth are now thin wrappers (~45 lines each)
  - ✅ ~700 lines of duplicated code eliminated

- [x] **7. Restore Credo DuplicatedCode check** (Medium)
  - ✅ Re-enabled `Credo.Check.Design.DuplicatedCode` in `.credo.exs`
  - ✅ Check passes (only test stubs have minor duplication, D-level only)

- [x] **8. Fail application start on missing provider config in prod** (Low)
  - ✅ Raises `ArgumentError` in `:prod` env when required keys are missing
  - ✅ Uses `Application.get_env(:doctrans, :env, :dev)` instead of `Mix.env()`

- [x] **9. Add deprecation warning for old :embedding config** (Low)
  - ✅ Warns if `:embedding` key is still set in config

- [x] **10. Run mix precommit and verify clean** (verification)
  - ✅ `mix deps.audit` — no vulnerabilities
  - ✅ `mix credo --strict` — no F/W-level issues
  - ✅ `mix format --check-formatted` — passes
  - ✅ 541 tests, 0 failures
