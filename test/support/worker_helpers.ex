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
  """
  def cleanup_worker_sandbox(tags) do
    if tags[:background_processes] do
      # Note: disallow/2 doesn't exist, the connection will be cleaned up automatically
      # when the test process exits
      :ok
    end

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
