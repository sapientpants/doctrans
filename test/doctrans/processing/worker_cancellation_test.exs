defmodule Doctrans.Processing.WorkerCancellationTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.Worker

  import Doctrans.Fixtures

  @moduletag :postgres

  test "cancels all pending states while preserving running, terminal, and unrelated jobs" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture()
      pages = for number <- 1..2, do: page_fixture(document, %{page_number: number})
      other_document = document_fixture()
      other_page = page_fixture(other_document)

      for state <- ~w(available scheduled retryable executing completed discarded cancelled) do
        # Literal keys also cover jobs persisted before the shared key definitions.
        extraction = insert_job(DocumentExtractionJob, %{"document_id" => document.id}, state)

        processing =
          Enum.map(pages, fn page ->
            insert_job(LlmProcessingJob, %{"page_id" => page.id}, state)
          end)

        other = insert_job(LlmProcessingJob, %{"page_id" => other_page.id}, state)

        unrelated =
          insert_job(DocumentExtractionJob, %{"document_id" => other_document.id}, state)

        assert :ok = Worker.cancel_document(document.id)
        expected = if state in ~w(available scheduled retryable), do: "cancelled", else: state

        for job <- [extraction | processing] do
          assert Repo.get!(Oban.Job, job.id).state == expected
        end

        assert Repo.get!(Oban.Job, other.id).state == state
        assert Repo.get!(Oban.Job, unrelated.id).state == state
      end
    end)
  end

  test "cancels extraction without pages and page reprocessing with custom options" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture()
      {:ok, extraction} = Worker.process_document(document.id, "/tmp/document.pdf")
      assert :ok = Worker.cancel_document(document.id)
      assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"

      page = page_fixture(document)
      {:ok, processing} = Worker.queue_page(page.id, page_number: 1)
      {:ok, reprocessing} = Worker.queue_page_reprocess(page.id, extraction_model: "custom")
      assert :ok = Worker.cancel_document(document.id)
      assert Repo.get!(Oban.Job, processing.id).state == "cancelled"
      assert Repo.get!(Oban.Job, reprocessing.id).state == "cancelled"
    end)
  end

  defp insert_job(worker, args, state) do
    args
    |> worker.new()
    |> Repo.insert!()
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
  end
end
