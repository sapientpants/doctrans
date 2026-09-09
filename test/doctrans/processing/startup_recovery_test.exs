defmodule Doctrans.Processing.StartupRecoveryTest do
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.StartupRecovery

  test "bounds each batch and resumes all remaining pages without duplicating jobs" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_with_pages_fixture(%{status: "processing"}, 105)

      assert {:pages, cursor} = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 50
      assert {:pages, cursor} = StartupRecovery.run_batch({:pages, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 100
      assert :done = StartupRecovery.run_batch({:pages, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 105
      assert :done = StartupRecovery.run_batch({:pages, nil})
      jobs = Repo.all(Oban.Job)
      assert Enum.all?(jobs, &(&1.meta["recovered"] == true))

      assert MapSet.new(Enum.map(jobs, & &1.args["page_id"])) ==
               MapSet.new(Enum.map(document.pages, & &1.id))
    end)
  end

  test "preserves completed stages, skips active jobs and broadcasts recovered progress" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "processing"})
      completed = completed_page_fixture(document)
      interrupted = page_fixture(document, %{page_number: 2, extraction_status: "processing"})

      translated =
        page_fixture(document, %{
          page_number: 3,
          extraction_status: "completed",
          original_markdown: "Saved text",
          translation_status: "processing"
        })

      active = page_fixture(document, %{page_number: 4, extraction_status: "processing"})
      %{"page_id" => active.id} |> LlmProcessingJob.new() |> Oban.insert!()
      Topics.subscribe_document(document.id)

      assert :done = StartupRecovery.run_batch({:pages, nil})
      assert Documents.get_page!(completed.id).translation_status == "completed"
      assert Documents.get_page!(interrupted.id).extraction_status == "pending"
      assert Documents.get_page!(active.id).extraction_status == "processing"
      saved = Documents.get_page!(translated.id)
      assert saved.extraction_status == "completed"
      assert saved.original_markdown == "Saved text"
      assert saved.translation_status == "pending"
      assert Repo.aggregate(Oban.Job, :count) == 3
      assert_received {:page_updated, _}
    end)
  end

  test "recovers extracting and queued documents, skipping existing jobs" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      queued = document_fixture(%{status: "queued"})
      extracting = document_fixture(%{status: "extracting"})
      %{"document_id" => queued.id} |> DocumentExtractionJob.new() |> Oban.insert!()

      assert {:pages, nil} = StartupRecovery.run_batch()
      assert Repo.aggregate(Oban.Job, :count) == 2
      assert Enum.any?(Repo.all(Oban.Job), &(&1.args["document_id"] == extracting.id))
    end)
  end

  test "does not recover pages after the document stops processing" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_with_pages_fixture(%{status: "processing"}, 51)
      assert {:pages, cursor} = StartupRecovery.run_batch({:pages, nil})
      {:ok, _} = Documents.update_document_status(document, "error")
      assert :done = StartupRecovery.run_batch({:pages, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 50
    end)
  end

  test "preserves work and avoids duplicate jobs queued after candidate selection" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{extraction_status: "processing"})

      after_candidate_selection(fn ->
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Concurrent result"
        })

        %{"page_id" => page.id} |> LlmProcessingJob.new() |> Oban.insert!()
      end)

      assert :done = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 1
      saved = Documents.get_page!(page.id)
      assert saved.extraction_status == "completed"
      assert saved.original_markdown == "Concurrent result"
    end)
  end

  test "rereads completed stages even without a conflicting job" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{extraction_status: "processing"})

      after_candidate_selection(fn ->
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "Concurrent result"
        })
      end)

      assert :done = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert Documents.get_page!(page.id).extraction_status == "completed"
    end)
  end

  test "does not recover a document stopped after candidate selection" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_with_pages_fixture(%{status: "processing"}, 1)
      after_candidate_selection(fn -> Documents.update_document_status(document, "error") end)
      assert :done = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 0
    end)
  end

  # Inject the competing write after the SELECT returns, before recovery locks
  # and rereads the candidate. This deterministically exercises the race window.
  defp after_candidate_selection(callback) do
    handler = {__MODULE__, make_ref()}
    Process.put(handler, callback)
    :telemetry.attach(handler, [:doctrans, :repo, :query], &__MODULE__.after_query/4, handler)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def after_query(_event, _measurements, metadata, handler) do
    if String.contains?(metadata.query, "NOT (exists") do
      case Process.delete(handler) do
        nil -> :ok
        callback -> callback.()
      end
    end
  end
end
