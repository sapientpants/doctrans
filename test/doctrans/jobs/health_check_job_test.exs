defmodule Doctrans.Jobs.HealthCheckJobTest do
  use Oban.Testing, repo: Doctrans.Repo
  use ExUnit.Case

  alias Doctrans.Jobs.HealthCheckJob

  test "new/1 creates job with correct queue" do
    job_changeset = HealthCheckJob.new(%{})

    assert job_changeset.changes.queue == "health_check"
    assert job_changeset.changes.args == %{}
    assert job_changeset.changes.worker == "Doctrans.Jobs.HealthCheckJob"
  end
end
