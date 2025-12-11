defmodule Doctrans.Jobs.LlmProcessingJobTest do
  use Oban.Testing, repo: Doctrans.Repo
  use ExUnit.Case

  alias Doctrans.Jobs.LlmProcessingJob

  test "new/1 creates job with correct args" do
    page_id = Uniq.UUID.uuid7()

    job_changeset =
      LlmProcessingJob.new(%{
        "page_id" => page_id,
        "operation" => "extract",
        "content" => "Test content"
      })

    assert job_changeset.changes.args["page_id"] == page_id
    assert job_changeset.changes.args["operation"] == "extract"
    assert job_changeset.changes.args["content"] == "Test content"
    assert job_changeset.changes.queue == "llm_processing"
    assert job_changeset.changes.worker == "Doctrans.Jobs.LlmProcessingJob"
  end
end
