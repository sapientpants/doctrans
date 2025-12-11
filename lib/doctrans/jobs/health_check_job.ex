defmodule Doctrans.Jobs.HealthCheckJob do
  @moduledoc """
  Periodic health check job for monitoring system status.
  Runs every minute to check the health of external services
  and internal processing components.
  """

  use Oban.Worker, queue: :health_check

  alias Doctrans.Resilience.HealthCheck

  @impl true
  def perform(%Oban.Job{}) do
    HealthCheck.check_all()
    :ok
  end

  @doc """
  Creates a new health check job.
  """
  def new(args) do
    %{
      args: args,
      queue: :health_check,
      worker: __MODULE__
    }
    |> Oban.Job.new()
  end
end
