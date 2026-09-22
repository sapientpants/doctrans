defmodule Doctrans.Processing.JobStatesTest do
  use Doctrans.DataCase

  import Doctrans.Fixtures

  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, LlmProcessingJob}
  alias Doctrans.Processing.JobStates

  # Oban runs inline in the test env, so enqueueing through a worker would
  # execute it instead of leaving it in the state under test. These rows are
  # staged directly to pin a state and an attempt count.
  defp stage(worker, queue, args, opts) do
    now = DateTime.utc_now()

    Repo.insert!(%Oban.Job{
      worker: Oban.Worker.to_string(worker),
      queue: queue,
      args: args,
      state: Keyword.get(opts, :state, "available"),
      attempt: Keyword.get(opts, :attempt, 0),
      max_attempts: 3,
      scheduled_at: now,
      inserted_at: now
    })
  end

  defp stage_page_job(page, opts),
    do: stage(LlmProcessingJob, "llm_processing", %{"page_id" => page.id}, opts)

  defp stage_index_job(page, opts) do
    args = %{"page_id" => page.id, "revision" => page.content_revision}
    stage(EmbeddingJob, "embedding_generation", args, opts)
  end

  setup do
    document = document_with_pages_fixture(%{status: "processing"}, 2)
    %{document: document, page: hd(document.pages)}
  end

  test "reports both pipelines idle when nothing is queued", %{document: document} do
    assert JobStates.for_document(document.id) == %{content: :idle, index: :idle}
  end

  test "a fresh available job is queued", %{document: document, page: page} do
    stage_page_job(page, [])

    assert %{content: :queued, index: :idle} = JobStates.for_document(document.id)
  end

  test "a scheduled job that has not attempted yet is queued", %{document: document, page: page} do
    stage_page_job(page, state: "scheduled")

    assert %{content: :queued} = JobStates.for_document(document.id)
  end

  test "an executing job is running", %{document: document, page: page} do
    stage_page_job(page, state: "executing", attempt: 1)

    assert %{content: :running, index: :idle} = JobStates.for_document(document.id)
  end

  test "a retryable job that burned an attempt is retrying", %{document: document, page: page} do
    stage_page_job(page, state: "retryable", attempt: 1)

    assert %{content: :retrying} = JobStates.for_document(document.id)
  end

  test "an available job that burned an attempt is retrying", %{document: document, page: page} do
    stage_page_job(page, state: "available", attempt: 1)

    assert %{content: :retrying} = JobStates.for_document(document.id)
  end

  test "running outranks retrying and queued", %{document: document} = ctx do
    [first, second] = ctx.document.pages
    stage_page_job(first, state: "retryable", attempt: 2)
    stage_page_job(second, state: "executing", attempt: 1)
    stage(DocumentExtractionJob, "pdf_extraction", %{"document_id" => document.id}, [])

    assert %{content: :running} = JobStates.for_document(document.id)
  end

  test "retrying outranks queued", %{document: document} = ctx do
    [first, second] = ctx.document.pages
    stage_page_job(first, [])
    stage_page_job(second, state: "retryable", attempt: 1)

    assert %{content: :retrying} = JobStates.for_document(document.id)
  end

  test "an extraction job is matched by its document id", %{document: document} do
    stage(DocumentExtractionJob, "pdf_extraction", %{"document_id" => document.id},
      state: "executing",
      attempt: 1
    )

    assert %{content: :running, index: :idle} = JobStates.for_document(document.id)
  end

  test "indexing is reported independently of content", %{document: document, page: page} do
    stage_index_job(page, state: "executing", attempt: 1)

    assert JobStates.for_document(document.id) == %{content: :idle, index: :running}
  end

  test "each pipeline keeps its own activity", %{document: document} = ctx do
    [first, second] = ctx.document.pages
    stage_page_job(first, state: "executing", attempt: 1)
    stage_index_job(second, state: "retryable", attempt: 2)

    assert JobStates.for_document(document.id) == %{content: :running, index: :retrying}
  end

  test "completed and discarded jobs are ignored", %{document: document, page: page} do
    stage_page_job(page, state: "completed", attempt: 1)
    stage_index_job(page, state: "discarded", attempt: 3)

    assert JobStates.for_document(document.id) == %{content: :idle, index: :idle}
  end

  test "jobs of another document do not leak in", %{document: document} do
    other = document_with_pages_fixture(%{status: "processing"}, 1)
    other_page = hd(other.pages)

    stage_page_job(other_page, state: "executing", attempt: 1)
    stage_index_job(other_page, state: "executing", attempt: 1)

    stage(DocumentExtractionJob, "pdf_extraction", %{"document_id" => other.id},
      state: "executing",
      attempt: 1
    )

    assert JobStates.for_document(document.id) == %{content: :idle, index: :idle}
    assert JobStates.for_document(other.id) == %{content: :running, index: :running}
  end
end
