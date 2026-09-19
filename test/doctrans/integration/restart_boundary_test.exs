defmodule Doctrans.Integration.RestartBoundaryTest do
  @moduledoc """
  What one startup pass does to a database a crash left mid-flight.

  `Doctrans.Processing.StartupRecoveryTest` drives each phase from its own
  cursor against a database holding work for that phase alone. Neither the
  handover between phases nor the documents phase's own batch bound is covered
  there: the phase order is what stops the completion phase from settling a page
  the page phase is about to retry, and the bound is what keeps a boot finite
  when the crash left thousands of documents behind.

  Async: nothing here touches application env, and `with_testing_mode/2` is
  process-local.
  """
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, LlmProcessingJob}
  alias Doctrans.Processing.StartupRecovery

  test "one pass walks all four phases in order and recovers each kind of interrupted work" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      unextracted = document_fixture(%{status: "queued"})
      {interrupted, done_page, stalled_page} = interrupted_document()
      unindexed_page = unindexed_page()
      unreconciled = unreconciled_document()

      assert run_to_done() == [
               {:pages, nil},
               {:embeddings, nil},
               {:completion, nil},
               :done
             ]

      assert [extraction] = jobs_for(DocumentExtractionJob)
      assert extraction.args["document_id"] == unextracted.id
      assert extraction.meta["recovered"] == true

      assert [processing] = jobs_for(LlmProcessingJob)
      assert processing.args["page_id"] == stalled_page.id
      assert processing.args["generation"] == stalled_page.processing_generation
      assert processing.meta["recovered"] == true

      assert [indexing] = jobs_for(EmbeddingJob)
      assert indexing.args["page_id"] == unindexed_page.id
      assert indexing.args["revision"] == unindexed_page.content_revision
      assert indexing.meta["recovered"] == true

      # The page phase rewinds the stage that was in flight and leaves the stage
      # that finished, so the retry costs one model call rather than two.
      stalled = Repo.get!(Page, stalled_page.id)
      assert stalled.extraction_status == "completed"
      assert stalled.translation_status == "pending"
      assert Repo.get!(Page, done_page.id).translation_status == "completed"

      # That document now has outstanding work again, so the completion phase
      # running after the page phase must leave it alone.
      assert Repo.get!(Document, interrupted.id).status == "processing"

      # The last phase queues nothing; it resolves the document whose pages all
      # settled while the document row never learned of it.
      assert Repo.get!(Document, unreconciled.id).status == "completed"
      assert Repo.aggregate(Oban.Job, :count) == 3
    end)
  end

  test "the documents phase bounds its batch and resumes from the id it hands back" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      for _ <- 1..51, do: document_fixture(%{status: "queued"})

      ids = Repo.all(from d in Document, order_by: [asc: d.id], select: d.id)
      assert length(ids) == 51

      assert {:documents, cursor} = StartupRecovery.run_batch()
      assert cursor == Enum.at(ids, 49)
      assert queued_document_ids() == Enum.take(ids, 50)

      assert {:pages, nil} = StartupRecovery.run_batch({:documents, cursor})
      assert queued_document_ids() == ids

      # Resuming from the same cursor a second time is the restart-during-restart
      # case: uniqueness holds, so the pass stays idempotent.
      assert {:pages, nil} = StartupRecovery.run_batch({:documents, cursor})
      assert queued_document_ids() == ids
    end)
  end

  # Every cursor the pass hands back, starting from the default first phase.
  defp run_to_done, do: collect(StartupRecovery.run_batch(), [])

  defp collect(:done, seen), do: Enum.reverse([:done | seen])
  defp collect(cursor, seen), do: collect(StartupRecovery.run_batch(cursor), [cursor | seen])

  # A document whose page jobs died mid-run: one page finished, the next was
  # translating when the node went down.
  defp interrupted_document do
    document = document_fixture(%{status: "processing", total_pages: 2})
    done = settled_page(document, 1)

    stalled =
      document
      |> page_fixture(%{
        page_number: 2,
        extraction_status: "completed",
        original_markdown: "Half a page",
        translation_status: "processing"
      })
      # Stamped so the generation the recovered job carries is a value the test
      # can tell apart from "no generation at all".
      |> Ecto.Changeset.change(processing_generation: Uniq.UUID.uuid7())
      |> Repo.update!()

    {document, done, indexed(stalled)}
  end

  # Extraction finished for this page but indexing never did, and its document
  # is no longer processing -- so only the embeddings phase can see it.
  defp unindexed_page do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_fixture(document, %{extraction_status: "completed", original_markdown: "Indexable"})
  end

  # Every page settled; the crash landed between the last page write and the
  # document update, so only the completion phase can resolve it.
  defp unreconciled_document do
    document = document_fixture(%{status: "processing", total_pages: 1})
    _page = settled_page(document, 1)
    document
  end

  defp settled_page(document, number) do
    document
    |> completed_page_fixture(%{page_number: number})
    |> indexed()
  end

  # Keeps the embeddings phase to the one page each test means it to find.
  defp indexed(page) do
    Repo.update!(Page.embedding_changeset(page, %{embedding_status: "completed"}))
  end

  defp jobs_for(module) do
    worker = Oban.Worker.to_string(module)

    from(j in Oban.Job, where: j.worker == ^worker, order_by: [asc: j.id])
    |> Repo.all()
  end

  defp queued_document_ids do
    DocumentExtractionJob
    |> jobs_for()
    |> Enum.map(& &1.args["document_id"])
    |> Enum.sort()
  end
end
