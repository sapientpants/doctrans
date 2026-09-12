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

  # Validation module pattern matching is intentionally exhaustive
  {"lib/doctrans/validation.ex", :pattern_match_cov},

  # Gettext.Plural.plural/3 opaque type mismatch (OTP 29/Expo library change)
  {"lib/doctrans_web/gettext.ex", :call_without_opaque}
]
