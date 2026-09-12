# Dialyzer ignore file
# Existing dependency limitations and deferred warnings.
# Audit with MIX_ENV=test mix dialyzer --list-unused-filters before adding filters.

[
  # Test fixtures - fire and forget operations
  {"test/support/fixtures.ex", :unmatched_return},
  {"test/support/worker_helpers.ex", :unmatched_return},

  # The crash stub exists to raise; only terminating with an exception is the point
  {"test/support/openai_crash_stub.ex", :no_return},

  # Resilience module specs are intentionally broad for flexibility
  {"lib/doctrans/resilience/circuit_breaker.ex", :contract_supertype},
  {"lib/doctrans/resilience/health_check.ex", :contract_supertype},
  {"lib/doctrans/processing/document_orchestrator.ex", :contract_supertype},
  {"lib/doctrans/processing/document_orchestrator.ex", :unknown_type},

  # Validation module pattern matching is intentionally exhaustive
  {"lib/doctrans/validation.ex", :pattern_match_cov},

  # Upload handling: the LiveView upload callback is untyped, so the temp file
  # path is inferred as binary(). Elixir 1.20 narrows File.stat/1 to String.t(),
  # which dialyzer cannot verify through to_string/1. LiveView guarantees the
  # path is a valid string at runtime.
  {"lib/doctrans_web/live/document_live/index.ex", :call},
  {"lib/doctrans_web/live/document_live/index.ex", :no_return},
  {"lib/doctrans_web/live/document_live/index.ex", :invalid_contract},

  # HtmlSanitizeEx.basic_html/1 type mismatch - returns string wrapped in Dialyzer incompatible type
  {"lib/doctrans_web/live/document_live/markdown_helpers.ex", :call},

  # Gettext.Plural.plural/3 opaque type mismatch (OTP 29/Expo library change)
  {"lib/doctrans_web/gettext.ex", :call_without_opaque}
]
