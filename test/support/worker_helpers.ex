defmodule Doctrans.TestSupport.WorkerHelpers do
  @moduledoc """
  Helper functions for testing Worker and other background processes.
  """

  alias Doctrans.Processing.Worker

  @doc """
  Sets up database for tests involving background processes.

  This ensures the Worker process can access the database with proper
  sandbox configuration.
  """
  def setup_worker_sandbox(tags) do
    # For tests involving background processes, ensure shared mode
    if tags[:background_processes] do
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Doctrans.Repo, :shared)

      # Allow the Worker process to use the shared connection
      Ecto.Adapters.SQL.Sandbox.allow(Doctrans.Repo, self(), Worker)
    end

    :ok
  end

  @doc """
  Cleans up after worker tests.

  Note: This is a no-op placeholder. The database connection is automatically
  cleaned up when the test process exits due to Ecto's sandbox ownership model.
  """
  def cleanup_worker_sandbox(_tags) do
    :ok
  end

  @doc """
  Waits for Worker to be responsive.
  """
  def ensure_worker_responsive(retries \\ 3)

  def ensure_worker_responsive(0), do: raise("Worker not responsive after retries")

  def ensure_worker_responsive(retries) do
    Worker.status()
  catch
    :exit, _ ->
      Process.sleep(100)
      ensure_worker_responsive(retries - 1)
  end
end
