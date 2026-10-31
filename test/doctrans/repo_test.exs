defmodule Doctrans.RepoTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Repo

  describe "safe_transaction/1" do
    test "returns the function's value on commit" do
      assert Repo.safe_transaction(fn -> :done end) == {:ok, :done}
    end

    test "normalizes a rollback value into an error reason" do
      assert Repo.safe_transaction(fn -> Repo.rollback(:document_not_found) end) ==
               {:error, :document_not_found}

      assert Repo.safe_transaction(fn -> Repo.rollback({:bad, :shape}) end) ==
               {:error, {:operation_failed, [reason: {:bad, :shape}]}}
    end

    test "reports a database failure as a database_error reason" do
      assert {:error, {:database_error, [reason: %Postgrex.Error{}]}} =
               Repo.safe_transaction(fn -> Repo.query!("select * from no_such_table") end)
    end
  end
end
