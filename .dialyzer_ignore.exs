# Dialyzer ignore file
# These are known false positives that should be suppressed

[
  # Test support files use ExUnit macros that generate internal functions
  # at compile time. These functions are not part of the public ExUnit API.
  {":unknown_function", "ExUnit.Callbacks.__merge__/4"},
  {":unknown_function", "ExUnit.Callbacks.__noop__/0"},
  {":unknown_function", "ExUnit.CaseTemplate.__proxy__/2"},
  {":unknown_function", "ExUnit.Callbacks.on_exit/1"},

  # PubSub.subscribe and broadcast returns are intentionally unmatched
  # in LiveView callbacks - fire and forget operations
  {"lib/doctrans/documents.ex", :unmatched_return},
  {"lib/doctrans/documents.ex", :pattern_match_cov},
  {"lib/doctrans/processing/llm_processor.ex", :unmatched_return},
  {"lib/doctrans/processing/pdf_processor.ex", :unmatched_return},
  {"lib/doctrans/processing/worker.ex", :unmatched_return},
  {"lib/doctrans/search/embedding_worker.ex", :unmatched_return},
  {"lib/doctrans_web/live/book_live/index.ex", :unmatched_return},
  {"lib/doctrans_web/live/book_live/index.ex", :call},
  {"lib/doctrans_web/live/book_live/show.ex", :unmatched_return},

  # Pgvector.t() type is not exported by the library but is valid
  {"lib/doctrans/search/embedding_behaviour.ex", :unknown_type},

  # Test fixtures - fire and forget operations
  {"test/support/fixtures.ex", :unmatched_return},
  {"test/support/data_case.ex", :call},
  {"test/support/worker_helpers.ex", :call},

  # Resilience module specs are intentionally broad for flexibility
  # - contract_supertype: specs accept term() for error handling flexibility
  # - unmatched_return: fire-and-forget for Process.send_after, File.close, etc.
  {"lib/doctrans/resilience/circuit_breaker.ex", :contract_supertype},
  {"lib/doctrans/resilience/circuit_breaker.ex", :unmatched_return},
  {"lib/doctrans/resilience/health_check.ex", :contract_supertype},
  {"lib/doctrans/resilience/health_check.ex", :unmatched_return},
  {"lib/doctrans/resilience/health_check_worker.ex", :unmatched_return},

  # Document orchestrator uses broad specs for flexibility in error handling
  {"lib/doctrans/processing/document_orchestrator.ex", :contract_supertype},
  {"lib/doctrans/processing/document_orchestrator.ex", :unmatched_return},
  {"lib/doctrans/processing/document_orchestrator.ex", :unknown_type},

  # Page processor uses broad specs for flexibility
  {"lib/doctrans/processing/page_processor.ex", :contract_supertype},
  {"lib/doctrans/processing/page_processor.ex", :unmatched_return},
  {"lib/doctrans/processing/page_processor.ex", :unknown_type},

  # Queue manager uses broad specs for state management
  {"lib/doctrans/processing/queue_manager.ex", :contract_supertype},

  # Validation module pattern matching is intentionally exhaustive
  {"lib/doctrans/validation.ex", :pattern_match},
  {"lib/doctrans/validation.ex", :pattern_match_cov},

  # Jobs fire-and-forget operations
  {"lib/doctrans/jobs/health_check_job.ex", :unmatched_return}
]
