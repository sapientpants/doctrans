defmodule Doctrans.Repo do
  use Ecto.Repo,
    otp_app: :doctrans,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs `fun` in a transaction and reports every way it can fail as one shape.

  A `rollback/1` value comes back as `{:error, Doctrans.Errors.reason()}`, and a
  database failure that would otherwise raise -- a lost connection, a constraint
  the changeset did not catch -- as `{:error, {:database_error, [reason: error]}}`.
  Not `transact/2`, which expects `fun` to return a result tuple itself.
  """
  @spec safe_transaction((-> value)) :: {:ok, value} | {:error, Doctrans.Errors.reason()}
        when value: var
  def safe_transaction(fun) when is_function(fun, 0) do
    transaction(fun) |> Doctrans.Errors.result()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, {:database_error, [reason: error]}}
  end

  @doc """
  Inserts an Oban job inside the caller's transaction, or rolls the transaction back.

  A unique conflict rolls back with `:already_processing`: the job already
  waiting belongs to the work this transaction is replacing, and would drop the
  new work as obsolete when it ran. Any other insert failure rolls back with
  its own reason.
  """
  @spec insert_job!(Ecto.Changeset.t()) :: Oban.Job.t()
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, %{conflict?: false} = job} -> job
      {:ok, _conflicting} -> rollback(:already_processing)
      {:error, reason} -> rollback(reason)
    end
  end
end
