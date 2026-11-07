defmodule Doctrans.Processing.DocumentReprocessingTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo
  import Doctrans.Fixtures
  alias Doctrans.Chat.Conversations
  alias Doctrans.Documents

  alias Doctrans.Documents.{
    Chunk,
    Layout,
    Lifecycle,
    Page,
    PageLifecycle,
    ProcessingStatus,
    Source
  }

  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob, RunCleanupJob}

  alias Doctrans.Processing.{
    DocumentConverterMocks,
    DocumentReprocessing,
    OpenAIMock,
    ResumablePdfExtractorStub,
    Run,
    StartupRecovery
  }

  setup do
    ResumablePdfExtractorStub.install()
    DocumentConverterMocks.retry()

    document =
      document_fixture(%{status: "completed", total_pages: 1, original_filename: "report.docx"})

    directory = Layout.document_dir(document.id)
    File.mkdir_p!(Path.join(directory, "pages"))
    source = Source.path(document)
    File.write!(source, "original office bytes")
    old_image = Path.join(directory, "pages/old.png")
    File.write!(old_image, "obsolete image")

    page =
      page_fixture(document, %{
        extraction_status: "completed",
        translation_status: "completed",
        original_markdown: "Old OCR",
        translated_markdown: "Old translation",
        image_path: Path.relative_to(old_image, Layout.root())
      })

    on_exit(fn -> File.rm_rf(directory) end)
    %{document: document, page: page, source: source, old_image: old_image}
  end

  test "the transaction refuses with the reason the read model withholds the control for" do
    for status <- ~w(uploading queued extracting processing) do
      document = document_fixture(%{status: status})
      document_source_fixture(document)

      assert ProcessingStatus.for_document(document).actions.reprocess_document ==
               {:refused, :already_processing}

      assert {:error, :already_processing} = DocumentReprocessing.reprocess_document(document.id)
    end

    missing = document_fixture(%{status: "completed"})

    assert ProcessingStatus.for_document(missing).actions.reprocess_document ==
             {:refused, :original_upload_missing}

    assert {:error, :original_upload_missing} =
             DocumentReprocessing.reprocess_document(missing.id)
  end

  test "full restart reconverts the actual original and renders fresh pages", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      # A previous converted PDF must never replace the original office input.
      File.write!(Path.join(Path.dirname(c.source), "original.pdf"), "obsolete conversion")
      Repo.insert!(%Chunk{page_id: c.page.id, chunk_index: 0, content: "Old OCR"})
      question = Conversations.start_question(c.document.id, "Historical question")

      Conversations.finish(question, "assistant", "Historical answer", [
        %{
          page_id: c.page.id,
          page_number: 1,
          similarity: 1.0,
          original_markdown: "Old OCR",
          translated_markdown: "Old translation"
        }
      ])

      assert {:ok, run} =
               DocumentReprocessing.reprocess_document(c.document.id,
                 extraction_model: "vision-v2",
                 translation_model: "text-v2"
               )

      assert run.id == c.document.id
      assert run.status == "queued"
      assert run.total_pages == nil
      assert Documents.list_pages(run.id) == []
      refute Repo.exists?(from ch in Chunk, where: ch.page_id == ^c.page.id)
      assert File.read!(c.source) == "original office bytes"
      assert length(Conversations.load(run.id).messages) == 2
      assert Conversations.load(run.id).context == []
      [job] = all_enqueued(worker: DocumentExtractionJob)
      assert job.args["run_id"] == run.processing_run_id
      assert :ok = DocumentExtractionJob.perform(job)

      assert File.read!(Path.join(Layout.output_dir(run), "original.pdf")) ==
               "original office bytes"

      pages = Documents.list_pages(run.id)
      assert length(pages) == 3

      assert Enum.all?(
               pages,
               &(&1.id != c.page.id && String.contains?(&1.image_path, run.processing_run_id))
             )

      for number <- 1..3, do: assert_received({:extracted_pdf_page, ^number})
      jobs = all_enqueued(worker: LlmProcessingJob)
      assert length(jobs) == 3

      assert Enum.all?(
               jobs,
               &(&1.args["extraction_model"] == "vision-v2" &&
                   &1.args["translation_model"] == "text-v2")
             )

      assert :ok = DocumentExtractionJob.perform(job)
      refute_received {:extracted_pdf_page, _}
      assert length(all_enqueued(worker: LlmProcessingJob)) == 3
      assert :ok = RunCleanupJob.perform(%Oban.Job{args: Run.args(run)})
      refute File.exists?(c.old_image)
      assert File.exists?(c.source)
      assert Enum.all?(pages, &File.regular?(Path.join(Layout.root(), &1.image_path)))
    end)
  end

  test "extraction retry after page completion restores completed status", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, run} = DocumentReprocessing.reprocess_document(c.document.id)
      [job] = all_enqueued(worker: DocumentExtractionJob)
      assert :ok = DocumentExtractionJob.perform(job)

      for page <- Documents.list_pages(run.id) do
        {:ok, page} =
          PageLifecycle.complete(page, :extraction, %{markdown: "New OCR"})

        {:ok, _} =
          PageLifecycle.complete(page, :translation, %{markdown: "New translation"})
      end

      assert :completed = Lifecycle.settle_unguarded(run.id)

      # Simulate rescue after page jobs finished but extraction was not acknowledged.
      Repo.update_all(from(j in Oban.Job), set: [state: "completed"])
      assert :ok = DocumentExtractionJob.perform(job)
      assert Documents.get_document(run.id).status == "completed"
      assert all_enqueued(worker: LlmProcessingJob) == []
      assert {:ok, _} = DocumentReprocessing.reprocess_document(run.id)
    end)
  end

  test "reprocessing resolves the persisted source extension after a metadata rename" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      # The start takes a fresh upload only.
      upload = document_fixture(%{original_filename: "report.docx"})
      source = document_source_fixture(upload, "original office bytes")
      assert {:ok, job} = Run.start(upload.id, source)

      document = Documents.get_document!(upload.id)
      assert document.source_extension == ".docx"

      assert {:ok, document} =
               Documents.update_document(document, %{original_filename: "renamed.pdf"})

      assert Source.path(document) == source

      # The start queued a run; a reprocess needs it settled, so stop it.
      Repo.delete!(job)
      assert {:ok, document} = Lifecycle.cancel(document)

      assert {:ok, run} = DocumentReprocessing.reprocess_document(document.id)

      [job] = all_enqueued(worker: DocumentExtractionJob)
      assert :ok = DocumentExtractionJob.perform(job)

      assert File.read!(Path.join(Layout.output_dir(run), "original.pdf")) ==
               "original office bytes"

      assert length(Documents.list_pages(run.id)) == 3
    end)
  end

  test "a page exhausted while rendering continues fails the document only once every page settles",
       c do
    Mox.stub(OpenAIMock, :translate, fn _markdown, _source, _target, _opts ->
      {:error, :circuit_open}
    end)

    owner = self()

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, run} = DocumentReprocessing.reprocess_document(c.document.id)
      [extraction_job] = all_enqueued(worker: DocumentExtractionJob)

      task =
        Task.async(fn ->
          Oban.Testing.with_testing_mode(:manual, fn ->
            Process.put(:pause_pdf_page, {3, owner})
            DocumentExtractionJob.perform(extraction_job)
          end)
        end)

      ResumablePdfExtractorStub.await_pause(task, 3)
      page = Documents.get_page_by_number(run.id, 1)

      {:ok, _} =
        PageLifecycle.complete(page, :extraction, %{
          markdown: "Extracted before rendering finished"
        })

      page_job =
        Enum.find(all_enqueued(worker: LlmProcessingJob), &(&1.args["page_id"] == page.id))

      assert {:error, _} = LlmProcessingJob.perform(%{page_job | attempt: page_job.max_attempts})
      Repo.update!(Ecto.Changeset.change(page_job, state: "discarded"))

      # The page is failed for good, but its siblings are still being rendered,
      # so the document is not: it reaches `error` only by settling.
      assert Documents.get_page!(page.id).translation_status == "error"
      assert Documents.get_document!(run.id).status == "extracting"

      send(task.pid, :resume_pdf)
      assert :ok = Task.await(task)
      # Extraction finishing keeps the page's verdict and settles nothing while
      # the other pages are still owed.
      assert Documents.get_page!(page.id).translation_status == "error"
      assert Documents.get_document!(run.id).status == "processing"

      # Once the remaining jobs finish, the failed document can be restarted.
      for remaining <- Documents.list_pages(run.id), remaining.id != page.id do
        {:ok, remaining} =
          PageLifecycle.complete(remaining, :extraction, %{markdown: ""})

        {:ok, _} =
          PageLifecycle.complete(remaining, :translation, %{markdown: ""})
      end

      # Settled pages with a discarded failure are a terminal partial failure,
      # named by the page that failed.
      assert :failed = Lifecycle.settle_unguarded(run.id)
      failed = Documents.get_document!(run.id)
      assert failed.status == "error"
      assert failed.error_message == inspect({:pages_failed, [page_numbers: "1"]})

      Repo.update_all(from(j in Oban.Job, where: j.state == "available"),
        set: [state: "completed"]
      )

      assert {:ok, _} = DocumentReprocessing.reprocess_document(run.id)
    end)
  end

  test "chat results are fenced by the run that supplied their context", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      context = [
        %{
          page_id: c.page.id,
          page_number: 1,
          similarity: 1.0,
          original_markdown: "Old OCR",
          translated_markdown: nil
        }
      ]

      saved = Conversations.start_question(c.document.id, "Finished before restart")

      assert {:ok, _} =
               Conversations.finish(saved, "assistant", "Old answer", context, c.document)

      pending = Conversations.start_question(c.document.id, "Still generating")
      assert {:ok, run} = DocumentReprocessing.reprocess_document(c.document.id)
      assert Conversations.load(run.id).context == []

      assert {:error, :obsolete_run} =
               Conversations.finish(pending, "assistant", "Late answer", context, c.document)

      snapshot = Conversations.load(run.id)
      assert snapshot.context == []
      assert length(snapshot.messages) == 3
      refute Repo.get!(Doctrans.Chat.Message, pending.id).completed

      current = Conversations.start_question(run.id, "New run question")
      assert {:ok, _} = Conversations.finish(current, "assistant", "New answer", [], run)
    end)
  end

  test "reprocessing one page invalidates only that page's chat context", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      other =
        page_fixture(c.document, %{
          page_number: 2,
          extraction_status: "completed",
          translation_status: "completed",
          original_markdown: "Unrelated",
          image_path: "documents/#{c.document.id}/pages/page_2.png"
        })

      context = [page_context(c.page, "Assets are 10"), page_context(other, "Unrelated")]
      answered = Conversations.start_question(c.document.id, "How much are assets?")
      assert {:ok, _} = Conversations.finish(answered, "assistant", "10", context, c.document)
      assert length(Conversations.load(c.document.id).context) == 2

      # An answer grounded in the old page is still generating when the page is corrected.
      in_flight = Conversations.start_question(c.document.id, "And after the correction?")
      assert {:ok, _} = DocumentReprocessing.reprocess_page(c.page.id)
      assert [%{page_id: kept}] = Conversations.load(c.document.id).context
      assert kept == other.id

      assert {:ok, _} =
               Conversations.finish(in_flight, "assistant", "Still 10", context, c.document)

      assert [%{page_id: ^kept}] = Conversations.load(c.document.id).context
    end)
  end

  defp page_context(page, content) do
    %{
      page_id: page.id,
      page_number: page.page_number,
      chunk_index: 0,
      content_revision: page.content_revision,
      similarity: 1.0,
      original_markdown: content,
      translated_markdown: nil
    }
  end

  test "missing original, invalid models, and duplicate submissions do not reset results", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:error, :invalid_model} =
               DocumentReprocessing.reprocess_document(c.document.id, extraction_model: " ")

      File.rm!(c.source)

      assert {:error, :original_upload_missing} =
               DocumentReprocessing.reprocess_document(c.document.id)

      assert Documents.get_page!(c.page.id).original_markdown == "Old OCR"
      File.write!(c.source, "restored original")
      assert {:ok, _} = DocumentReprocessing.reprocess_document(c.document.id)

      assert {:error, :already_processing} =
               DocumentReprocessing.reprocess_document(c.document.id)

      assert length(all_enqueued(worker: DocumentExtractionJob)) == 1
    end)
  end

  for state <- ~w(available scheduled executing retryable suspended) do
    @state state
    test "active #{@state} page job prevents replacement", c do
      Oban.Testing.with_testing_mode(:manual, fn ->
        job = LlmProcessingJob.new(%{"page_id" => c.page.id}) |> Oban.insert!()
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: @state])

        assert {:error, :already_processing} =
                 DocumentReprocessing.reprocess_document(c.document.id)

        assert Documents.get_page!(c.page.id).original_markdown == "Old OCR"
        assert Documents.get_document!(c.document.id).status == "completed"
      end)
    end
  end

  test "job insertion failure rolls back deletion, model choices, and run status", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      # The UUID is generated by our fixture; this constraint exists only in the
      # sandbox transaction and forces failure after the generated rows are deleted.
      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT reject_restart_test CHECK ((args->>'document_id') IS DISTINCT FROM '#{c.document.id}') NOT VALID"
      )

      assert {:error, {:database_error, _}} =
               DocumentReprocessing.reprocess_document(c.document.id)

      assert Documents.get_page!(c.page.id).original_markdown == "Old OCR"

      assert Documents.get_document!(c.document.id).processing_run_id ==
               c.document.processing_run_id

      assert File.read!(c.source) == "original office bytes"
      refute_enqueued(worker: DocumentExtractionJob)
    end)
  end

  test "single-page recovery preserves pending choices and rejects obsolete jobs", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, page} =
        DocumentReprocessing.reprocess_page(c.page.id,
          extraction_model: "override-vision",
          translation_model: "override-text"
        )

      [job] = all_enqueued(worker: LlmProcessingJob)
      Repo.delete!(job)
      StartupRecovery.run_batch({:pages, nil})
      [recovered] = all_enqueued(worker: LlmProcessingJob)
      assert recovered.args["extraction_model"] == "override-vision"
      assert recovered.args["generation"] == page.processing_generation
      assert :ok = LlmProcessingJob.perform(%Oban.Job{args: %{"page_id" => page.id}})
      assert Documents.get_page!(page.id).original_markdown == nil
    end)
  end

  test "late writes and jobs from a replaced run cannot alter current content", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, run} = DocumentReprocessing.reprocess_document(c.document.id)
      assert {:error, :obsolete_run} = Lifecycle.begin_extraction(c.document)

      assert {:error, :obsolete_run} =
               PageLifecycle.complete(c.page, :extraction, %{markdown: "late"})

      assert :ok = DocumentExtractionJob.perform(%Oban.Job{args: %{"document_id" => run.id}})
      assert Documents.list_pages(run.id) == []
      assert Documents.get_document!(run.id).status == "queued"
    end)
  end

  test "recovery keeps the run and its model choices", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, run} =
        DocumentReprocessing.reprocess_document(c.document.id,
          extraction_model: "chosen-vision",
          translation_model: "chosen-text"
        )

      Repo.delete_all(
        from j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(DocumentExtractionJob)
      )

      StartupRecovery.run_batch()
      [job] = all_enqueued(worker: DocumentExtractionJob)
      assert job.args["run_id"] == run.processing_run_id
      assert :ok = DocumentExtractionJob.perform(job)

      Repo.delete_all(
        from j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(LlmProcessingJob)
      )

      StartupRecovery.run_batch({:pages, nil})

      jobs = all_enqueued(worker: LlmProcessingJob)
      pages = Documents.list_pages(run.id)
      assert length(jobs) == 3

      assert Enum.sort(Enum.map(jobs, & &1.args["page_id"])) ==
               Enum.sort(Enum.map(pages, & &1.id))

      for job <- jobs do
        assert job.args["translation_model"] == "chosen-text"
        assert job.args["extraction_model"] == "chosen-vision"
      end
    end)
  end

  test "exhausted page jobs expose a retryable document error without false provenance", c do
    Mox.stub(OpenAIMock, :extract_markdown, fn _image_path, _opts -> {:error, :circuit_open} end)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, page} =
        DocumentReprocessing.reprocess_page(c.page.id, extraction_model: "failed-model")

      [job] = all_enqueued(worker: LlmProcessingJob)
      assert {:error, _} = LlmProcessingJob.perform(%{job | attempt: job.max_attempts})
      assert Documents.get_page!(page.id).extraction_model == nil
      assert Documents.get_document!(c.document.id).status == "error"
    end)
  end

  test "empty extracted text skips translation without inventing a model", c do
    {:ok, page} = PageLifecycle.complete(c.page, :extraction, %{markdown: ""})
    assert :ok = LlmProcessingJob.perform(%Oban.Job{args: %{"page_id" => page.id}})
    page = Documents.get_page!(page.id)
    assert page.translation_status == "completed"
    assert page.translation_model == nil
  end

  test "page result provenance follows successful stages and resets to unknown", c do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, page} =
               DocumentReprocessing.reprocess_page(c.page.id,
                 extraction_model: "page-vision",
                 translation_model: "page-text"
               )

      assert page.extraction_model == nil
      [job] = all_enqueued(worker: LlmProcessingJob)
      assert :ok = LlmProcessingJob.perform(job)
      page = Repo.get!(Page, page.id)
      assert page.extraction_model == "page-vision"
      assert page.translation_model == "page-text"
      assert page.translation_status == "completed"

      assert Documents.get_document!(c.document.id).extraction_model ==
               c.document.extraction_model

      # Metadata survives removal of its queue record.
      Repo.delete!(job)
      assert Repo.get!(Page, page.id).translation_model == "page-text"
    end)
  end
end
