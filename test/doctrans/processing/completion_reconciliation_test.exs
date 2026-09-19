defmodule Doctrans.Processing.CompletionReconciliationTest do
  # Every case here swaps the global :openai_module for a stub that raises on
  # any call, which is how they prove no model request is made. Reconciliation
  # decides from rows that are already saved, so that holds for the startup
  # phase as much as for a replay.
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{LlmProcessor, OpenAICrashStub, StartupRecovery}

  # The state a crash between the last page write and the document update
  # leaves behind: every page saved, the document still "processing".
  defp interrupted_document(page_attrs) do
    document = document_fixture(%{status: "processing", total_pages: length(page_attrs)})

    pages =
      Enum.map(page_attrs, fn
        {number, :completed} -> completed_page_fixture(document, %{page_number: number})
        {number, attrs} -> page_fixture(document, Map.put(attrs, :page_number, number))
      end)

    assert Documents.get_document!(document.id).status == "processing"
    {document, pages}
  end

  setup do
    previous_module = Application.fetch_env!(:doctrans, :openai_module)
    Application.put_env(:doctrans, :openai_module, OpenAICrashStub)
    on_exit(fn -> Application.put_env(:doctrans, :openai_module, previous_module) end)
    :ok
  end

  describe "job replay" do
    test "a replay whose stages are all saved completes the document" do
      {document, [_first, last]} = interrupted_document([{1, :completed}, {2, :completed}])

      assert LlmProcessor.process_page(last.id, MapSet.new(),
               generation: last.processing_generation
             ) == :ok

      assert Documents.get_document!(document.id).status == "completed"
    end

    # The other replay cases call the processor directly. This one goes through
    # Oban so the job wrapper — arg decoding, the generation option, and the
    # exhausted-job settlement around the result — is covered too.
    test "a replayed Oban job completes the document" do
      {document, [_first, last]} = interrupted_document([{1, :completed}, {2, :completed}])

      assert perform_job(
               LlmProcessingJob,
               LlmProcessingJob.page_args(last, last.processing_generation, %{})
             ) ==
               :ok

      assert Documents.get_document!(document.id).status == "completed"
    end

    test "a replay settles a document whose remaining pages failed" do
      {document, [_failed, last]} =
        interrupted_document([{1, %{extraction_status: "error"}}, {2, :completed}])

      assert LlmProcessor.process_page(last.id, MapSet.new(),
               generation: last.processing_generation
             ) == :ok

      settled = Documents.get_document!(document.id)
      assert settled.status == "error"
      assert settled.error_message == inspect({:pages_failed, [page_numbers: "1"]})
    end

    test "a replay leaves a document with outstanding work processing" do
      {document, [saved, _pending]} = interrupted_document([{1, :completed}, {2, %{}}])

      assert LlmProcessor.process_page(saved.id, MapSet.new(),
               generation: saved.processing_generation
             ) == :ok

      assert Documents.get_document!(document.id).status == "processing"
    end
  end

  describe "startup reconciliation" do
    test "completes a document whose pages all finished, without queueing work" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {document, _pages} = interrupted_document([{1, :completed}, {2, :completed}])
        Topics.subscribe_document(document.id)

        assert :done = StartupRecovery.run_batch({:completion, nil})
        assert Documents.get_document!(document.id).status == "completed"
        assert Repo.aggregate(Oban.Job, :count) == 0
        assert_received {:document_updated, %{status: "completed"}}
      end)
    end

    test "settles a document whose pages all failed, naming the pages to reprocess" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {document, _pages} =
          interrupted_document([
            {1, :completed},
            {2, %{extraction_status: "error"}},
            {3, %{extraction_status: "completed", translation_status: "error"}}
          ])

        assert :done = StartupRecovery.run_batch({:completion, nil})

        settled = Documents.get_document!(document.id)
        assert settled.status == "error"
        assert settled.error_message == inspect({:pages_failed, [page_numbers: "2, 3"]})
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "leaves a failed page that still has a pending retry alone" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {document, [_completed, failed]} =
          interrupted_document([{1, :completed}, {2, %{extraction_status: "error"}}])

        %{"page_id" => failed.id} |> LlmProcessingJob.new() |> Oban.insert!()

        assert :done = StartupRecovery.run_batch({:completion, nil})
        assert Documents.get_document!(document.id).status == "processing"
      end)
    end

    test "leaves a document with an unfinished page alone" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {document, _pages} = interrupted_document([{1, :completed}, {2, %{}}])

        assert :done = StartupRecovery.run_batch({:completion, nil})
        assert Documents.get_document!(document.id).status == "processing"
      end)
    end

    # Reconciliation runs after the page phase so that a failed page recovery is
    # about to retry does not settle its document as an error first.
    test "a failed page requeued by the page phase is not settled as a failure" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {document, [_completed, failed]} =
          interrupted_document([{1, :completed}, {2, %{extraction_status: "error"}}])

        assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})
        assert {:completion, nil} = StartupRecovery.run_batch({:embeddings, nil})
        assert :done = StartupRecovery.run_batch({:completion, nil})

        assert Documents.get_document!(document.id).status == "processing"
        assert Documents.get_page!(failed.id).extraction_status == "pending"

        assert Repo.exists?(
                 from(j in Oban.Job,
                   where: j.worker == ^Oban.Worker.to_string(LlmProcessingJob),
                   where: fragment("?->>'page_id' = ?", j.args, ^failed.id)
                 )
               )
      end)
    end

    # Only a "processing" document is mid-run. Reconciling an "error" document
    # would resurrect one an operator or a document-level failure deliberately
    # stopped, and would overwrite the diagnostic that stopped it.
    test "leaves a document that already failed alone" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {document, _pages} = interrupted_document([{1, :completed}])

        {:ok, failed} = Documents.update_document_status(document, "error", "stopped")

        assert :done = StartupRecovery.run_batch({:completion, nil})

        unchanged = Documents.get_document!(failed.id)
        assert unchanged.status == "error"
        assert unchanged.error_message == "stopped"
      end)
    end

    test "bounds the batch and resumes from the cursor" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        documents =
          for _ <- 1..51 do
            {document, _pages} = interrupted_document([{1, :completed}])
            document
          end

        assert {:completion, cursor} = StartupRecovery.run_batch({:completion, nil})
        assert completed_count(documents) == 50
        assert :done = StartupRecovery.run_batch({:completion, cursor})
        assert completed_count(documents) == 51
      end)
    end
  end

  defp completed_count(documents) do
    Enum.count(documents, &(Documents.get_document!(&1.id).status == "completed"))
  end
end
