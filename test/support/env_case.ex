defmodule Doctrans.EnvCase do
  @moduledoc """
  An ExUnit case that registers application-environment isolation without a database.

  Tests overriding global settings must use `async: false`. `Doctrans.TestEnv`
  checks that registration before changing anything and restores the old value
  when the test exits. DataCase and ConnCase register the same information.
  """

  use ExUnit.CaseTemplate

  setup tags do
    Doctrans.TestEnv.record_async(tags)
    :ok
  end
end
