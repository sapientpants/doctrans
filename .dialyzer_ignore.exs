# Dialyzer ignore file
# These are known false positives that should be suppressed

[
  # Test support files use ExUnit macros that generate internal functions
  # at compile time. These functions are not part of the public ExUnit API.
  {":unknown_function", "ExUnit.Callbacks.__merge__/4"},
  {":unknown_function", "ExUnit.Callbacks.__noop__/0"},
  {":unknown_function", "ExUnit.CaseTemplate.__proxy__/2"},
  {":unknown_function", "ExUnit.Callbacks.on_exit/1"},

  # Pgvector.t() type is not exported by the library but is valid
  {"lib/doctrans/search/embedding_behaviour.ex", :unknown_type},

  # Test fixtures - fire and forget operations
  {"test/support/fixtures.ex", :unmatched_return},
  {"test/support/data_case.ex", :call},
  {"test/support/worker_helpers.ex", :call},
  {"test/support/worker_helpers.ex", :unmatched_return},

  # Resilience module specs are intentionally broad for flexibility
  {"lib/doctrans/resilience/circuit_breaker.ex", :contract_supertype},
  {"lib/doctrans/resilience/health_check.ex", :contract_supertype},
  {"lib/doctrans/processing/document_orchestrator.ex", :contract_supertype},
  {"lib/doctrans/processing/document_orchestrator.ex", :unknown_type},
  {"lib/doctrans/processing/page_processor.ex", :contract_supertype},
  {"lib/doctrans/processing/page_processor.ex", :unknown_type},
  {"lib/doctrans/processing/page_processor.ex", :contract_with_opaque},
  {"lib/doctrans/processing/queue_manager.ex", :contract_supertype},

  # Validation module pattern matching is intentionally exhaustive
  {"lib/doctrans/validation.ex", :pattern_match},
  {"lib/doctrans/validation.ex", :pattern_match_cov},

  # Ecto Repo.insert/1 returns changeset on error — dialyzer doesn't track the type
  {"lib/doctrans/documents.ex", :pattern_match},

  # HtmlSanitizeEx.basic_html/1 type mismatch - returns string wrapped in Dialyzer incompatible type
  {"lib/doctrans_web/live/book_live/markdown_helpers.ex", :call},

  # Gettext.Plural.plural/3 opaque type mismatch (OTP 29/Expo library change)
  {"lib/doctrans_web/gettext.ex", :call_without_opaque},

  # ErrorClassifier.classify/1 - clauses never match due to OTP 29 FileSystem.chroot/2 reason type change
  {"lib/doctrans/resilience/error_classifier.ex", :unmatched_return},
  {"lib/doctrans/resilience/error_classifier.ex", :unused},

  # Ecto.Adapters.SQL.Sandbox.mode/2 second argument type changed in OTP 29 (expects {:shared, pid(), ...})
  {"test/support/data_case.ex", :contract_supertype},
  {"test/support/worker_helpers.ex", :contract_supertype}
]
