defmodule Doctrans.Repo do
  use Ecto.Repo,
    otp_app: :doctrans,
    adapter: Ecto.Adapters.Postgres

  @after_commit {__MODULE__, :after_commit}

  @doc """
  Runs `fun` in a transaction and reports every way it can fail as one shape.

  A `rollback/1` value comes back as `{:error, Doctrans.Errors.reason()}`, and a
  database failure that would otherwise raise -- a lost connection, a constraint
  the changeset did not catch -- as `{:error, {:database_error, [reason: error]}}`.
  Not `transact/2`, which expects `fun` to return a result tuple itself.

  Work queued with `after_commit/1` inside `fun` runs once the outermost
  `safe_transaction/1` has committed, in the order it was queued, and is
  dropped when the transaction rolls back or raises.
  """
  @spec safe_transaction((-> value)) :: {:ok, value} | {:error, Doctrans.Errors.reason()}
        when value: var
  def safe_transaction(fun) when is_function(fun, 0) do
    if in_transaction?(), do: guarded(fun), else: outermost(fun)
  end

  @doc """
  Runs `fun` once the transaction in progress has committed, or right away when
  none is open.

  This is how a write announces itself without knowing whether it is inside a
  caller's transaction: `Doctrans.Documents.Lifecycle` queues every broadcast
  here, so no caller re-announces after its own commit. Only
  `safe_transaction/1` delivers the queue; a bare `transaction/1` around such
  work drops it, which `Doctrans.Fixtures` relies on to build documents
  silently.
  """
  @spec after_commit((-> any())) :: :ok
  def after_commit(fun) when is_function(fun, 0) do
    if in_transaction?() do
      Process.put(@after_commit, [fun | Process.get(@after_commit, [])])
    else
      _ = fun.()
    end

    :ok
  end

  # A queue left behind by a bare transaction is discarded here rather than
  # delivered on behalf of a transaction this call knows nothing about.
  defp outermost(fun) do
    Process.delete(@after_commit)
    result = guarded(fun)
    queued = Process.delete(@after_commit) || []

    if match?({:ok, _}, result), do: queued |> Enum.reverse() |> Enum.each(& &1.())
    result
  end

  defp guarded(fun) do
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
