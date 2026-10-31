defmodule Doctrans.EnvCase do
  @moduledoc """
  An ExUnit case for tests that need no database.

  It registers the test with `Doctrans.TestEnv`, so an application-environment
  override is refused from an `async: true` test and restored when the test
  exits, and it installs the default mock stubs through `Doctrans.Mocks`.
  DataCase and ConnCase register the same information.
  """

  use ExUnit.CaseTemplate

  setup tags do
    Doctrans.TestEnv.record_async(tags)
    Doctrans.Mocks.setup(tags)
    :ok
  end
end
