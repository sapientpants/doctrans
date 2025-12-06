# Dialyzer ignore file
# These are known false positives that should be suppressed

[
  # Test support files use ExUnit macros that generate internal functions
  # at compile time. These functions are not part of the public ExUnit API.
  {":unknown_function", "ExUnit.Callbacks.__merge__/4"},
  {":unknown_function", "ExUnit.Callbacks.__noop__/0"},
  {":unknown_function", "ExUnit.CaseTemplate.__proxy__/2"},
  {":unknown_function", "ExUnit.Callbacks.on_exit/1"}
]
