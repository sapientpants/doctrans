defmodule Doctrans.Documents.ProcessingStatusTest do
  use Doctrans.DataCase

  import Doctrans.Fixtures

  alias Doctrans.Documents.ProcessingStatus
  alias Doctrans.Jobs.{EmbeddingJob, LlmProcessingJob}

  # Oban runs inline in tests, so a normal enqueue would execute the job instead
  # of leaving it in the state under test. The worker still builds the row, so
  # queue and args stay the job module's business, and only the state and the
  # attempt count are forced.
  defp stage(changeset, opts) do
    Oban.Testing.with_testing_mode(:manual, fn -> Oban.insert!(changeset) end)
    |> change(
      state: Keyword.get(opts, :state, "available"),
      attempt: Keyword.get(opts, :attempt, 0)
    )
    |> Repo.update!()
  end

  defp stage_page_job(page, opts),
    do: %{"page_id" => page.id} |> LlmProcessingJob.new() |> stage(opts)

  defp stage_index_job(page, opts),
    do: page |> EmbeddingJob.page_args() |> EmbeddingJob.new() |> stage(opts)

  # `embedding_status` is outside every page changeset, and `cancelled` is not
  # in the document changeset's inclusion list, so both are set structurally.
  defp force(record, attrs), do: record |> change(attrs) |> Repo.update!()

  defp indexed_page(document, page_number, embedding_status) do
    document
    |> completed_page_fixture(%{
      page_number: page_number,
      image_path: "documents/#{document.id}/pages/page_#{page_number}.png"
    })
    |> force(%{embedding_status: embedding_status})
  end

  defp offered?(status, action), do: status.actions[action] == :offered

  defp failed_page(document, page_number) do
    page_fixture(document, %{
      page_number: page_number,
      image_path: "documents/#{document.id}/pages/page_#{page_number}.png",
      extraction_status: "error"
    })
  end

  describe "content state" do
    test "a completed document reports completed" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      _page = indexed_page(document, 1, "completed")

      status = ProcessingStatus.for_document(document)

      assert status.document_id == document.id
      assert status.content == :completed
      assert status.failed_page_count == 0
      assert status.failed_pages == []
      assert status.progress == 100.0
      refute offered?(status, :cancel)
      refute offered?(status, :retry_pages)
    end

    test "a cancelled document reports cancelled" do
      document = document_fixture(%{status: "processing"}) |> force(%{status: "cancelled"})

      status = ProcessingStatus.for_document(document)

      assert status.content == :cancelled
      refute offered?(status, :cancel)
    end

    test "an errored document with a failed page reports failed and lists the page" do
      document = document_fixture(%{status: "error", total_pages: 2})
      _completed = indexed_page(document, 1, "completed")
      _failed = failed_page(document, 2)

      status = ProcessingStatus.for_document(document)

      assert status.content == :failed
      assert status.failed_pages == [2]
      assert status.failed_page_count == 1
      # One page through both steps, one through neither: two of four steps.
      assert status.progress == 50.0
      assert status.pages == %{expected: 2, translated: 1, failed: 1, outstanding: 0}
      assert offered?(status, :retry_pages)
    end

    test "an errored document whose failed page still has a retry reports retrying" do
      document = document_fixture(%{status: "error", total_pages: 1})
      page = failed_page(document, 1)
      stage_page_job(page, state: "retryable", attempt: 1)

      status = ProcessingStatus.for_document(document)

      assert status.content == :retrying
      assert status.failed_page_count == 1
      # A retry already scheduled must not be offered again.
      refute offered?(status, :retry_pages)
    end

    test "an errored document with a job still executing reports running" do
      document = document_fixture(%{status: "error", total_pages: 2})
      failed = failed_page(document, 1)
      stage_page_job(failed_page(document, 2), state: "executing", attempt: 1)

      status = ProcessingStatus.for_document(document)

      # The document's own recorded failure is not the last word while a job of
      # its own is still running: offering a retry here promises something
      # `Run.active?/1` would refuse.
      assert status.content == :running
      assert status.failed_pages == [failed.page_number, 2]
      refute offered?(status, :retry_pages)
    end

    test "an in-progress document with no job is idle, not running" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      _page = page_fixture(document)

      assert ProcessingStatus.for_document(document).content == :idle
    end

    test "progress reads as zero until the page count is known" do
      document = document_fixture(%{status: "extracting"})
      _page = indexed_page(document, 1, "completed")

      assert ProcessingStatus.for_document(document).progress == 0.0
    end

    test "a pre-extraction document with no job is queued" do
      for status <- ~w(uploading queued extracting) do
        document = document_fixture(%{status: status})

        assert ProcessingStatus.for_document(document).content == :queued
      end
    end

    test "a live content job is reported over the document status" do
      document = document_fixture(%{status: "processing", total_pages: 1})
      page = page_fixture(document)
      stage_page_job(page, state: "executing", attempt: 1)

      assert ProcessingStatus.for_document(document).content == :running
    end

    test "a queued content job on an in-progress document is queued" do
      document = document_fixture(%{status: "processing", total_pages: 1})
      page = page_fixture(document)
      stage_page_job(page, [])

      assert ProcessingStatus.for_document(document).content == :queued
    end
  end

  describe "page counts" do
    test "outstanding counts the pages not yet created once the total is known" do
      document = document_fixture(%{status: "processing", total_pages: 4})
      _completed = indexed_page(document, 1, "pending")

      status = ProcessingStatus.for_document(document)

      assert status.pages == %{expected: 4, translated: 1, failed: 0, outstanding: 3}
    end

    test "outstanding falls back to the unsettled rows while the total is unknown" do
      document = document_fixture(%{status: "extracting"})
      _pending = page_fixture(document, %{page_number: 1})
      _failed = failed_page(document, 2)

      status = ProcessingStatus.for_document(document)

      assert status.pages == %{expected: nil, translated: 0, failed: 1, outstanding: 1}
    end

    test "translated, failed and outstanding add up to the expected total" do
      document = document_fixture(%{status: "error", total_pages: 3})
      _completed = indexed_page(document, 1, "completed")
      _failed = failed_page(document, 2)
      _pending = page_fixture(document, %{page_number: 3})

      status = ProcessingStatus.for_document(document)

      assert status.failed_page_count == status.pages.failed
      assert status.pages.translated + status.pages.failed + status.pages.outstanding == 3
    end

    test "a settled document leaves nothing outstanding" do
      document = document_fixture(%{status: "error", total_pages: 2})
      _completed = indexed_page(document, 1, "completed")
      _failed = failed_page(document, 2)

      status = ProcessingStatus.for_document(document)

      assert status.pages.translated + status.pages.failed + status.pages.outstanding == 2
      assert status.pages.outstanding == 0
    end
  end

  describe "index state" do
    test "nothing extracted reports none rather than pending" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      _page = page_fixture(document)

      status = ProcessingStatus.for_document(document)

      assert status.index == :none
      assert status.indexing == %{indexable: 0, indexed: 0, failed: 0, outstanding: 0}
      refute offered?(status, :retry_index)
    end

    test "extracted but unindexed pages are pending" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      _page = indexed_page(document, 1, "pending")

      status = ProcessingStatus.for_document(document)

      assert status.index == :pending
      assert status.indexing == %{indexable: 1, indexed: 0, failed: 0, outstanding: 1}
      assert offered?(status, :retry_index)
    end

    test "every extracted page indexed is ready" do
      document = document_fixture(%{status: "completed", total_pages: 2})
      _first = indexed_page(document, 1, "completed")
      _second = indexed_page(document, 2, "completed")

      status = ProcessingStatus.for_document(document)

      assert status.index == :ready
      assert status.indexing == %{indexable: 2, indexed: 2, failed: 0, outstanding: 0}
      refute offered?(status, :retry_index)
    end

    test "some indexed and none failed is partial" do
      document = document_fixture(%{status: "completed", total_pages: 2})
      _first = indexed_page(document, 1, "completed")
      _second = indexed_page(document, 2, "pending")

      status = ProcessingStatus.for_document(document)

      assert status.index == :partial
      assert status.indexing == %{indexable: 2, indexed: 1, failed: 0, outstanding: 1}
      assert offered?(status, :retry_index)
    end

    test "an errored embedding is failed and stays outstanding" do
      document = document_fixture(%{status: "completed", total_pages: 2})
      _first = indexed_page(document, 1, "completed")
      _second = indexed_page(document, 2, "error")

      status = ProcessingStatus.for_document(document)

      assert status.index == :failed
      assert status.indexing == %{indexable: 2, indexed: 1, failed: 1, outstanding: 1}
      assert offered?(status, :retry_index)
    end

    test "a running index job outranks the stored counts" do
      document = document_fixture(%{status: "completed", total_pages: 2})
      _first = indexed_page(document, 1, "completed")
      second = indexed_page(document, 2, "pending")
      stage_index_job(second, state: "executing", attempt: 1)

      status = ProcessingStatus.for_document(document)

      assert status.index == :running
      # The counts still say partial; the job is about to change them.
      assert status.indexing.indexed == 1
      refute offered?(status, :retry_index)
    end

    test "a retrying index job is reported as retrying" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      page = indexed_page(document, 1, "error")
      stage_index_job(page, state: "retryable", attempt: 2)

      status = ProcessingStatus.for_document(document)

      assert status.index == :retrying
      refute offered?(status, :retry_index)
    end

    test "a queued index job is reported as queued" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      page = indexed_page(document, 1, "pending")
      stage_index_job(page, [])

      assert ProcessingStatus.for_document(document).index == :queued
    end

    test "content jobs do not change the index state" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      first = indexed_page(document, 1, "pending")
      stage_page_job(first, state: "executing", attempt: 1)

      status = ProcessingStatus.for_document(document)

      assert status.content == :running
      assert status.index == :pending
    end
  end

  describe "actions" do
    test "cancel is offered while the document is still in flight" do
      for status <- ~w(uploading queued extracting processing) do
        document = document_fixture(%{status: status})

        assert ProcessingStatus.for_document(document).actions.cancel == :offered
      end
    end

    test "cancel is withheld once the document is terminal, with the transaction's refusal" do
      for status <- ~w(completed error) do
        document = document_fixture(%{status: status})

        assert ProcessingStatus.for_document(document).actions.cancel ==
                 {:refused, :not_cancellable}
      end
    end

    test "page retry is offered only when a failure is settled" do
      document = document_fixture(%{status: "error", total_pages: 1})
      page = failed_page(document, 1)

      assert ProcessingStatus.for_document(document).actions.retry_pages == :offered

      # The same failure with a retry still scheduled is not settled.
      stage_page_job(page, state: "retryable", attempt: 1)

      assert ProcessingStatus.for_document(document).actions.retry_pages ==
               {:refused, :already_processing}
    end

    test "page retry is withheld while the pipeline is still working" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      _failed = failed_page(document, 1)
      second = page_fixture(document, %{page_number: 2})
      stage_page_job(second, state: "executing", attempt: 1)

      status = ProcessingStatus.for_document(document)

      assert status.failed_page_count == 1
      assert status.content == :running
      assert status.actions.retry_pages == {:refused, :already_processing}
    end

    test "page retry is withheld when nothing failed" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      _page = indexed_page(document, 1, "completed")

      assert ProcessingStatus.for_document(document).actions.retry_pages ==
               {:refused, :nothing_to_retry}
    end

    test "index retry is withheld once the index is ready" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      _page = indexed_page(document, 1, "completed")

      assert ProcessingStatus.for_document(document).actions.retry_index ==
               {:refused, :nothing_to_retry}
    end

    test "index retry is withheld while an index job is live, and offered once it is not" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      page = indexed_page(document, 1, "error")

      assert ProcessingStatus.for_document(document).actions.retry_index == :offered

      stage_index_job(page, state: "executing")

      assert ProcessingStatus.for_document(document).actions.retry_index ==
               {:refused, :already_processing}
    end

    test "document reprocess is offered exactly where the lifecycle admits a fresh run" do
      for status <- ~w(completed error cancelled) do
        document = document_fixture(%{status: status})
        document_source_fixture(document)

        assert ProcessingStatus.for_document(document).actions.reprocess_document == :offered
      end

      for status <- ~w(uploading queued extracting processing) do
        document = document_fixture(%{status: status})
        document_source_fixture(document)

        assert ProcessingStatus.for_document(document).actions.reprocess_document ==
                 {:refused, :already_processing}
      end
    end

    test "document reprocess needs the original upload, after the status has been checked" do
      document = document_fixture(%{status: "completed"})

      assert ProcessingStatus.for_document(document).actions.reprocess_document ==
               {:refused, :original_upload_missing}

      # Both refusals apply: the status one is reported, as the transaction does.
      processing = document_fixture(%{status: "processing"})

      assert ProcessingStatus.for_document(processing).actions.reprocess_document ==
               {:refused, :already_processing}
    end

    test "a straggling job withholds reprocess and retry on a settled document" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      document_source_fixture(document)
      page = failed_page(document, 1)
      stage_page_job(page, state: "executing", attempt: 1)

      status = ProcessingStatus.for_document(document)

      # The display state keeps the terminal verdict; the actions do not.
      assert status.content == :completed
      assert status.actions.reprocess_document == {:refused, :already_processing}
      assert status.actions.retry_pages == {:refused, :already_processing}
      assert status.actions.reprocess_page == {:refused, :already_processing}
    end

    test "page reprocess follows the document, not the page's own status" do
      document = document_fixture(%{status: "processing", total_pages: 1})
      stuck = page_fixture(document, %{extraction_status: "processing"})

      # Nothing is running, so a page stuck mid-stage is exactly what a user
      # would reprocess.
      status = ProcessingStatus.for_document(document)
      assert ProcessingStatus.reprocess_page(status, stuck) == :offered
      assert ProcessingStatus.reprocess_page(status, nil) == {:refused, :page_not_found}

      for pre <- ~w(uploading queued extracting) do
        early = document_fixture(%{status: pre})
        page = page_fixture(early)

        assert ProcessingStatus.reprocess_page(ProcessingStatus.for_document(early), page) ==
                 {:refused, :already_processing}
      end
    end
  end
end
