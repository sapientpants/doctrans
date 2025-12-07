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
  {"lib/doctrans/processing/llm_processor.ex", :unmatched_return},
  {"lib/doctrans/processing/pdf_processor.ex", :unmatched_return},
  {"lib/doctrans/processing/worker.ex", :unmatched_return},
  {"lib/doctrans/search/embedding_worker.ex", :unmatched_return},
  {"lib/doctrans_web/live/book_live/index.ex", :unmatched_return},
  {"lib/doctrans_web/live/book_live/show.ex", :unmatched_return},

  # Pgvector.t() type is not exported by the library but is valid
  {"lib/doctrans/search/embedding_behaviour.ex", :unknown_type},

  # Test fixtures - fire and forget operations
  {"test/support/fixtures.ex", :unmatched_return}
]
