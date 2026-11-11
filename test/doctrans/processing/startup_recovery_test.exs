defmodule Doctrans.Processing.StartupRecoveryTest do
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Lifecycle, Page, PageLifecycle}
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, LlmProcessingJob}
  alias Doctrans.Processing.StartupRecovery

  test "bounds each batch and resumes all remaining pages without duplicating jobs" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_with_pages_fixture(%{status: "processing"}, 105)

      assert {:pages, cursor} = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 50
      assert {:pages, cursor} = StartupRecovery.run_batch({:pages, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 100
      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 105
      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})
      jobs = Repo.all(Oban.Job)

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

      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})
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

  # The job of a run re-queued by an earlier boot, discarded again. Oban keeps
  # each attempt's error as the formatted exception, stack trace and all.
  defp discarded_recovered_job(document, error) do
    %{"document_id" => document.id, "run_id" => document.processing_run_id}
    |> DocumentExtractionJob.new(meta: %{recovered: true})
    |> Oban.insert!()
    |> Ecto.Changeset.change(
      state: "discarded",
      attempt: 3,
      errors: [%{"attempt" => 3, "at" => DateTime.utc_now(), "error" => error}]
    )
    |> Repo.update!()
  end

  test "fails a document whose recovered extraction job was discarded again" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "extracting"})
      Topics.subscribe_document(document.id)

      discarded =
        discarded_recovered_job(
          document,
          "** (Oban.TimeoutError) Doctrans.Jobs.DocumentExtractionJob timed out after 3900000ms\n" <>
            "    (oban 2.24.2) lib/oban/queues/executor.ex:132: Oban.Queues.Executor.start_timeout/1"
        )

      assert {:pages, nil} = StartupRecovery.run_batch()

      # No new job: the run has now been given its attempts twice over, so the
      # document is failed where the killed job could not fail it, with the
      # job's last error named on the row and the failure announced.
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert Repo.get!(Oban.Job, discarded.id).state == "discarded"

      saved = Documents.get_document!(document.id)
      assert saved.status == "error"
      assert saved.error_message =~ "extraction_attempts_exhausted"
      assert saved.error_message =~ "timed out after 3900000ms"
      refute saved.error_message =~ "executor.ex"
      assert_received {:document_updated, %{status: "error"}}
    end)
  end

  test "re-queues once a document whose extraction job was discarded before any recovery" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "extracting"})

      %{"document_id" => document.id, "run_id" => document.processing_run_id}
      |> DocumentExtractionJob.new()
      |> Oban.insert!()
      |> Ecto.Changeset.change(state: "discarded", attempt: 3)
      |> Repo.update!()

      assert {:pages, nil} = StartupRecovery.run_batch()

      # A restart is a fair new attempt for a job that was never recovered; the
      # job it queues is marked, so the next boot can tell it apart.
      assert [recovered] = Repo.all(from j in Oban.Job, where: j.state == "available")
      assert recovered.args["document_id"] == document.id
      assert recovered.meta["recovered"] == true
      assert Documents.get_document!(document.id).status == "extracting"
    end)
  end

  test "judges a document by its latest extraction job, not an older run's" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "extracting"})
      _older = discarded_recovered_job(document, "** (RuntimeError) older run")

      # The run's current job, discarded without ever being recovered.
      %{"document_id" => document.id, "run_id" => document.processing_run_id}
      |> DocumentExtractionJob.new()
      |> Oban.insert!()
      |> Ecto.Changeset.change(state: "discarded", attempt: 3)
      |> Repo.update!()

      assert {:pages, nil} = StartupRecovery.run_batch()

      assert [_recovered] = Repo.all(from j in Oban.Job, where: j.state == "available")
      assert Documents.get_document!(document.id).status == "extracting"
    end)
  end

  test "does not recover pages after the document stops processing" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_with_pages_fixture(%{status: "processing"}, 51)
      assert {:pages, cursor} = StartupRecovery.run_batch({:pages, nil})
      {:ok, _} = Lifecycle.fail(document, :stopped)
      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 50
    end)
  end

  test "preserves work and avoids duplicate jobs queued after candidate selection" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{extraction_status: "processing"})

      after_candidate_selection(fn ->
        {:ok, _} = PageLifecycle.complete(page, :extraction, %{markdown: "Concurrent result"})

        %{"page_id" => page.id} |> LlmProcessingJob.new() |> Oban.insert!()
      end)

      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})
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
        {:ok, _} = PageLifecycle.complete(page, :extraction, %{markdown: "Concurrent result"})
      end)

      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert Documents.get_page!(page.id).extraction_status == "completed"
    end)
  end

  test "does not recover a document stopped after candidate selection" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_with_pages_fixture(%{status: "processing"}, 1)
      after_candidate_selection(fn -> Lifecycle.fail(document, :stopped) end)
      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})
      assert Repo.aggregate(Oban.Job, :count) == 0
    end)
  end

  test "recovers indexing for extracted pages of documents the page phase never sees" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      translated = completed_page_fixture(document)
      indexed = completed_page_fixture(document, %{page_number: 2, embedding_status: "completed"})
      errored = completed_page_fixture(document, %{page_number: 3, embedding_status: "error"})

      # Interrupted mid-indexing: the status stayed "processing" across the restart.
      interrupted =
        completed_page_fixture(document, %{page_number: 4, embedding_status: "processing"})

      pending = page_fixture(document, %{page_number: 5, extraction_status: "processing"})

      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})
      jobs = Repo.all(Oban.Job)
      assert Enum.all?(jobs, &(&1.worker == Oban.Worker.to_string(EmbeddingJob)))
      assert Enum.all?(jobs, &(&1.meta["recovered"] == true))

      assert MapSet.new(jobs, & &1.args["page_id"]) ==
               MapSet.new([translated.id, errored.id, interrupted.id])

      refute Enum.any?(jobs, &(&1.args["page_id"] in [indexed.id, pending.id]))

      assert Enum.all?(
               jobs,
               &(&1.args["revision"] == Repo.get!(Page, &1.args["page_id"]).content_revision)
             )
    end)
  end

  test "leaves indexing that already has an active job alone" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      page = completed_page_fixture(document)
      page |> EmbeddingJob.page_args() |> EmbeddingJob.new() |> Oban.insert!()

      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert [job] = Repo.all(Oban.Job)
      refute job.meta["recovered"]
    end)
  end

  # A job holding a superseded revision cancels rather than indexing, so treating
  # it as the owner of the page — as a page-keyed filter does — strands the
  # revision that replaced it until some later restart. Oban's uniqueness cannot
  # account for this outcome: the job recovery must insert is for a revision no
  # existing job holds.
  test "recovers the current revision while a superseded job is still active" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      page = completed_page_fixture(document)

      stale_job = page |> EmbeddingJob.page_args() |> EmbeddingJob.new() |> Oban.insert!()

      {:ok, rewritten} =
        PageLifecycle.complete(page, :extraction, %{
          markdown: "Rewritten while the old job waited"
        })

      assert rewritten.content_revision > page.content_revision

      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})

      assert Repo.aggregate(Oban.Job, :count) == 2
      assert [recovered] = Repo.all(from j in Oban.Job, where: j.id != ^stale_job.id)
      assert recovered.args["revision"] == rewritten.content_revision
      assert recovered.meta["recovered"] == true
    end)
  end

  # `cancelled` is not one of the worker's unique states, so nothing but the
  # recovery filter can keep this page from being queued again on every boot.
  test "leaves a revision that a cancelled job already gave up on alone" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      page = completed_page_fixture(document, %{embedding_status: "error"})

      page
      |> EmbeddingJob.page_args()
      |> EmbeddingJob.new()
      |> Oban.insert!()
      |> Ecto.Changeset.change(state: "cancelled")
      |> Repo.update!()

      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})
      assert Repo.aggregate(Oban.Job, :count) == 1
    end)
  end

  # Exhausted retries are not a verdict on the content the way a cancel is: those
  # failures were classified retryable, so a restart is a fair new attempt.
  test "re-queues a revision whose retries were exhausted" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      page = completed_page_fixture(document, %{embedding_status: "error"})

      page
      |> EmbeddingJob.page_args()
      |> EmbeddingJob.new()
      |> Oban.insert!()
      |> Ecto.Changeset.change(state: "discarded")
      |> Repo.update!()

      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})

      assert Repo.aggregate(Oban.Job, :count) == 2
      assert [recovered] = Repo.all(from j in Oban.Job, where: j.state == "available")
      assert recovered.meta["recovered"] == true
    end)
  end

  test "bounds the embedding batch and resumes from the cursor" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      for number <- 1..51, do: completed_page_fixture(document, %{page_number: number})

      assert {:embeddings, cursor} = StartupRecovery.run_batch({:embeddings, nil})
      assert Repo.aggregate(Oban.Job, :count) == 50
      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 51
      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, cursor})
      assert Repo.aggregate(Oban.Job, :count) == 51
    end)
  end

  test "queues the revision a page holds when it changes after candidate selection" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "completed"})
      page = completed_page_fixture(document)

      after_candidate_selection(fn ->
        {:ok, _} =
          PageLifecycle.complete(page, :extraction, %{markdown: "Rewritten after selection"})
      end)

      assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})
      assert [job] = Repo.all(Oban.Job)
      current = Repo.get!(Page, page.id)
      assert current.content_revision > page.content_revision
      assert job.args["revision"] == current.content_revision
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
