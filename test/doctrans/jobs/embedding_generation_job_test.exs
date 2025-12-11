defmodule Doctrans.Jobs.EmbeddingGenerationJobTest do
  use Oban.Testing, repo: Doctrans.Repo
  use ExUnit.Case

  alias Doctrans.Jobs.EmbeddingGenerationJob

  test "new/1 creates job with correct args" do
    page_id = Uniq.UUID.uuid7()
    content = "Test content"

    job_changeset =
      EmbeddingGenerationJob.new(%{
        "page_id" => page_id,
        "content" => content
      })

    assert job_changeset.changes.args["page_id"] == page_id
    assert job_changeset.changes.args["content"] == content
    assert job_changeset.changes.queue == "embedding_generation"
    assert job_changeset.changes.worker == "Doctrans.Jobs.EmbeddingGenerationJob"
  end
end
