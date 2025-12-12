defmodule Doctrans.Jobs.HealthCheckJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Jobs.HealthCheckJob

  describe "perform/1" do
    test "executes health check and returns :ok" do
      # The health check job should always return :ok
      # (even if individual checks fail, the job itself succeeds)
      assert :ok = perform_job(HealthCheckJob, %{})
    end
  end
end
