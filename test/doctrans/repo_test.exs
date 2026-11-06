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

  describe "after_commit/1" do
    test "runs right away outside a transaction" do
      assert :ok = Repo.after_commit(fn -> send(self(), :ran) end)
      assert_received :ran
    end

    test "runs queued work in order once the outermost transaction commits" do
      assert {:ok, :done} =
               Repo.safe_transaction(fn ->
                 Repo.after_commit(fn -> send(self(), :first) end)

                 {:ok, :inner} =
                   Repo.safe_transaction(fn ->
                     Repo.after_commit(fn -> send(self(), :second) end)
                     :inner
                   end)

                 refute_received :first
                 refute_received :second
                 :done
               end)

      assert_received :first
      assert_received :second
    end

    test "drops queued work when the transaction rolls back or raises" do
      assert {:error, :no} =
               Repo.safe_transaction(fn ->
                 Repo.after_commit(fn -> send(self(), :never) end)
                 Repo.rollback(:no)
               end)

      assert {:error, {:database_error, _}} =
               Repo.safe_transaction(fn ->
                 Repo.after_commit(fn -> send(self(), :never) end)
                 Repo.query!("select * from no_such_table")
               end)

      refute_received :never
    end

    test "a bare transaction leaves the queue undelivered, and the next safe one discards it" do
      {:ok, :ok} = Repo.transaction(fn -> Repo.after_commit(fn -> send(self(), :stale) end) end)
      refute_received :stale

      assert {:ok, :fresh} = Repo.safe_transaction(fn -> :fresh end)
      refute_received :stale
    end
  end
end
