# TODO: feature/unsloth-provider — post-review tasks

## Security

- [ ] **1. Hardcoded session signing salt** (High)
  - `endpoint.ex:10` uses a fixed `signing_salt: "Qr5ZNHs0"` that's committed to the repo.
  - Replace with `System.get_env("PHX_SECRET_KEY_BASE")` or derive from `:secret_key_base` so
    each deployment gets a unique salt.

- [ ] **2. Document show LiveView still references `:ollama` config directly** (Medium)
  - `book_live/show.ex:27` reads `Application.get_env(:doctrans, :ollama, [])` for default
    model names and `book_live/show.ex:477` calls `Ollama.list_models()` directly instead of
    going through `ProviderResolver`. If the active provider is Unsloth, the reprocess modal
    will fetch Ollama models and show an Ollama-specific error message.

- [ ] **3. `ProviderResolver` silently accepts non-module values in `:provider_module`** (Medium)
  - `provider_resolver.ex:29` returns `{:ok, module}` for any truthy `:provider_module` value
    without verifying it is an actual module or implements `ProviderBehaviour`. A typo in test
    config could surface as a runtime crash deep in a pipeline.

- [ ] **4. `search_live.ex:225` — URL-encoded query in `push_patch`** (Low)
  - The query string is interpolated directly into the patch URL without URI encoding.
  - Use `URI.encode_query/1` or `Plug.Conn.Query.encode/1` to prevent issues with special
    characters.

## Quality

- [ ] **5. Duplicate `language_name/1` map in `LlmUtils` and `HttpProvider`** (Medium)
  - Both `llm_utils.ex:18` and `http_provider.ex:361` define the identical language map.
  - Consolidate into a single `@languages` module attribute in `LlmUtils` and import it in
    `HttpProvider`.

- [ ] **6. `HttpProvider` top-level struct is unused** (Low)
  - `http_provider.ex:11` defines `defstruct config_key, circuit_key, name, config` at the
    module level but only the nested `Config` module struct is actually used. Remove the
    top-level struct to avoid confusion.

- [ ] **7. `ProviderConfig.validate/0` doesn't validate `:timeout` key** (Low)
  - The `@required_keys` list omits `:timeout`. If a provider config is missing `:timeout`,
    `HttpProvider` will crash with a `KeyError` on `config[:timeout]`. Either add `:timeout`
    to required keys or provide a sensible default in `HttpProvider`.

- [ ] **8. `HttpProvider.chat/3` has a different default timeout than other methods** (Low)
  - `chat/3` defaults to `120_000ms` while `extract_markdown` and `translate` use the config
    value. Consider aligning or documenting the discrepancy.

- [ ] **9. `book_live/show.ex` should use `ProviderResolver` for model list** (Medium)
  - The `:fetch_available_models` handler calls `Ollama.list_models()` directly at line 477.
  - Should call `ProviderResolver.resolve!().list_models()` so the modal works for Unsloth.

- [ ] **10. Add integration test for provider switch** (Medium)
  - No test verifies that switching `:provider` from `:ollama` to `:unsloth` end-to-end
    affects chat, extraction, translation, embedding, and health check paths. Add a test
    that flips the config and asserts the correct provider module is called.
