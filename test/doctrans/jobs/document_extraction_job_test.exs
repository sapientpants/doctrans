defmodule Doctrans.Jobs.DocumentExtractionJobTest do
  # `async: false`: the timeout case overrides the global `:pdf_extraction`
  # application env.
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Config.{DocumentConversion, PdfExtraction}
  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Topics}
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.{DocumentConverterMocks, PdfExtractorMock, PdfExtractorStub}
  alias Doctrans.TestEnv

  import Doctrans.Fixtures

  describe "timeout/1" do
    test "bounds the job, and follows configuration" do
      job = %Oban.Job{args: %{}}

      # The property that matters is that the job is bounded at all: Oban waits
      # forever without this, and a hung extraction would hold the single slot.
      timeout = DocumentExtractionJob.timeout(job)
      assert is_integer(timeout)
      assert timeout > 0

      original = Application.get_env(:doctrans, :pdf_extraction, [])

      # Still bounded with the key removed entirely.
      TestEnv.put_env(:pdf_extraction, Keyword.delete(original, :job_timeout))
      assert is_integer(DocumentExtractionJob.timeout(job))

      TestEnv.put_env(:pdf_extraction, Keyword.put(original, :job_timeout, 5_000))
      assert DocumentExtractionJob.timeout(job) > 5_000
    end

    test "is an outer guard strictly wider than the budget and the steps outside it" do
      # Oban arms its timer before `perform/1` and kills the job process when it
      # fires, with no verdict written for the document. The in-process budget
      # does not clamp the LibreOffice conversion or the page count, so the
      # guard has to outlast all three for the budget to be the deadline that
      # fires.
      job = %Oban.Job{args: %{}}

      budget = PdfExtraction.job_timeout()
      unclamped = DocumentConversion.timeout() + PdfExtraction.info_timeout()

      assert DocumentExtractionJob.timeout(job) > budget + unclamped
    end
  end

  describe "the render budget" do
    test "is armed as the job begins and handed to every page render" do
      document = document_fixture()
      document_source_fixture(document)
      owner = self()

      Mox.stub(PdfExtractorMock, :extract_page, fn pdf_path, output_dir, page_number, opts ->
        send(owner, {:deadline, page_number, Keyword.fetch!(opts, :deadline)})
        PdfExtractorStub.extract_page(pdf_path, output_dir, page_number, opts)
      end)

      started_at = System.monotonic_time(:millisecond)
      assert :ok = perform_job(DocumentExtractionJob, %{"document_id" => document.id})
      finished_at = System.monotonic_time(:millisecond)

      # One deadline for the whole document, counted from the start of the job
      # rather than from the first render: the same instant reaches every page.
      assert_received {:deadline, 1, deadline}
      assert_received {:deadline, 2, ^deadline}
      assert_received {:deadline, 3, ^deadline}
      assert deadline >= started_at + PdfExtraction.job_timeout()
      assert deadline <= finished_at + PdfExtraction.job_timeout()
    end

    test "running out fails the document cleanly and leaves the retry to Oban" do
      document = document_fixture()
      document_source_fixture(document)
      Topics.subscribe_document(document.id)

      Mox.stub(PdfExtractorMock, :extract_page, fn _pdf_path, _output_dir, _page_number, _opts ->
        {:error, :pdf_extraction_deadline_exceeded}
      end)

      # Retryable, not cancelled: the pages that did render are kept, so the
      # next attempt resumes from them rather than spending the budget again on
      # the same pages.
      assert {:error, {:pdf_extraction_failed, [reason: :pdf_extraction_deadline_exceeded]}} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      saved = Documents.get_document!(document.id)
      assert saved.status == "error"
      assert saved.error_message =~ "pdf_extraction_deadline_exceeded"
      assert_received {:document_updated, %{status: "error"}}
    end
  end

  describe "deterministic failures" do
    # Fails the extractor's page count, the first thing extraction asks it for.
    defp fail_with(reason) do
      Mox.stub(PdfExtractorMock, :get_page_count, fn _pdf_path -> {:error, reason} end)
    end

    test "a document over the page limit is cancelled rather than retried" do
      document = document_fixture()
      document_source_fixture(document)

      # Every attempt reaches the same answer, so retrying only burns the
      # document's remaining attempts and re-occupies the single extraction slot.
      fail_with({:pdf_too_many_pages, [pages: 9999, limit: 1000]})

      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      # The reason arrives wrapped by the processor, so the cancellation has to
      # recognise the nested failure rather than the wrapper.
      assert names_failure?(reason, :pdf_too_many_pages)
    end

    test "a missing poppler install is cancelled rather than retried" do
      document = document_fixture()
      document_source_fixture(document)

      fail_with({:poppler_not_found, [command: "pdftoppm"]})

      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      assert names_failure?(reason, :poppler_not_found)
    end

    test "a render timeout is cancelled rather than retried" do
      # A page that could not be rendered within its deadline cannot be rendered
      # within it on the next attempt either; retrying only holds the single
      # extraction slot, and the host's memory, for the same deadline again.
      document = document_fixture()
      document_source_fixture(document)

      fail_with(:pdf_command_timeout)

      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      assert names_failure?(reason, :pdf_command_timeout)
    end

    defp names_failure?(reason, tag) when is_atom(reason), do: reason == tag

    defp names_failure?({name, bindings}, tag) when is_list(bindings) do
      name == tag or names_failure?(Keyword.get(bindings, :reason, :none), tag)
    end

    test "a missing LibreOffice is cancelled rather than retried" do
      document = document_fixture(%{original_filename: "report.docx"})

      upload_dir = Layout.document_dir(document.id)
      File.mkdir_p!(upload_dir)
      File.write!(Path.join(upload_dir, "original.docx"), "fake docx content")
      on_exit(fn -> File.rm_rf!(upload_dir) end)

      DocumentConverterMocks.missing()

      # No number of retries installs LibreOffice, and each one re-occupies the
      # single extraction slot to reach the same answer.
      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      assert names_failure?(reason, :soffice_not_found)
    end

    defp names_failure?(_reason, _tag), do: false
  end

  describe "perform/1" do
    test "cancels when the document row is gone" do
      fake_document_id = Uniq.UUID.uuid7()

      # A deleted document does not come back, so there is nothing to retry.
      assert {:cancel, :document_not_found} =
               perform_job(DocumentExtractionJob, %{"document_id" => fake_document_id})
    end

    test "cancels a missing source and publishes the document error once" do
      document = document_fixture()
      Topics.subscribe_document(document.id)

      # Marked and broadcast on this attempt; a retry would only do both again
      # against the same absent file, so the job gives up here.
      assert {:cancel, :document_file_not_found} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      saved = Documents.get_document!(document.id)
      assert saved.status == "error"
      assert saved.error_message == ":document_file_not_found"
      assert_received {:document_updated, %{id: id, status: "error"}}
      assert id == document.id
      assert Documents.list_pages(document.id) == []
    end

    test "ignores a legacy file_path arg and reads the source from the layout" do
      document = document_fixture()
      document_source_fixture(document)

      # Jobs queued before the arg was dropped still carry an absolute path into
      # the root the application had then; the layout is what locates the file.
      stale_path = Path.join([System.tmp_dir!(), "doctrans-old-root", "original.pdf"])
      refute File.regular?(stale_path)

      assert :ok =
               perform_job(DocumentExtractionJob, %{
                 "document_id" => document.id,
                 "file_path" => stale_path
               })

      assert_completed_extraction(document)
    end

    test "extracts the retained PDF" do
      document = document_fixture()
      pdf_path = document_source_fixture(document)

      assert :ok = perform_job(DocumentExtractionJob, %{"document_id" => document.id})
      assert_completed_extraction(document)
      assert File.regular?(pdf_path)
    end

    test "finds document with original extension when pdf doesn't exist" do
      document = document_fixture(%{original_filename: "test.docx"})

      docx_path = document_source_fixture(document, "retained office input")

      DocumentConverterMocks.retry()

      assert :ok = perform_job(DocumentExtractionJob, %{"document_id" => document.id})
      assert_completed_extraction(document)

      pdf_path = docx_path |> Path.dirname() |> Path.join("original.pdf")
      assert File.read!(pdf_path) == "retained office input"

      assert File.read!(docx_path) == "retained office input"
    end
  end

  defp assert_completed_extraction(document) do
    saved = Documents.get_document_with_pages(document.id)
    assert saved.status == "completed"
    assert saved.total_pages == 3
    assert Enum.map(saved.pages, & &1.page_number) == [1, 2, 3]

    for page <- saved.pages do
      assert page.extraction_status == "completed"
      assert page.translation_status == "completed"
      assert File.regular?(Path.join(Layout.root(), page.image_path))
    end
  end
end
