defmodule Doctrans.DataCase do
  @moduledoc """
  The case template for tests of the data layer and everything above it that
  needs no connection.

  `setup_sandbox/1` is the one setup every database-backed test runs, and
  `DoctransWeb.ConnCase` delegates to it. It checks out a SQL sandbox
  connection -- shared with every process when the test is `async: false`,
  owned by the test alone when it is `async: true` -- registers the test with
  `Doctrans.TestEnv`, so an application-env override is refused from an async
  test and restored when the test exits, and installs the default Mox stubs
  through `Doctrans.Mocks`, in the mode the `async` tag calls for.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Doctrans.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Doctrans.DataCase
    end
  end

  setup tags do
    Doctrans.DataCase.setup_sandbox(tags)

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # Lets `Doctrans.TestEnv` refuse a global application-env override from a
    # test that runs concurrently with others.
    Doctrans.TestEnv.record_async(tags)
    Doctrans.Mocks.setup(tags)

    pid = Sandbox.start_owner!(Doctrans.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
