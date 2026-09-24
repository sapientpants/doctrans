defmodule Doctrans.Jobs.DocumentExtractionJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.MissingConverterStub
  alias Doctrans.Processing.PdfExtractorFailingStub
  alias Doctrans.Processing.RetryDocumentConverterStub
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
      assert timeout != :infinity

      original = Application.get_env(:doctrans, :pdf_extraction, [])
      on_exit(fn -> Application.put_env(:doctrans, :pdf_extraction, original) end)

      # Still bounded with the key removed entirely.
      Application.put_env(:doctrans, :pdf_extraction, Keyword.delete(original, :job_timeout))
      assert is_integer(DocumentExtractionJob.timeout(job))

      Application.put_env(:doctrans, :pdf_extraction, Keyword.put(original, :job_timeout, 5_000))
      assert DocumentExtractionJob.timeout(job) == 5_000
    end
  end

  describe "deterministic failures" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "extraction_job_#{System.pid()}_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "original.pdf")
      File.write!(path, "%PDF-1.4\n" <> String.duplicate("0", 1_024))

      original_module = Application.fetch_env(:doctrans, :pdf_extractor_module)
      Application.put_env(:doctrans, :pdf_extractor_module, PdfExtractorFailingStub)

      on_exit(fn ->
        restore_env(:pdf_extractor_module, original_module)
        Application.delete_env(:doctrans, :test_extraction_failure)
      end)

      %{path: path}
    end

    defp fail_with(reason), do: Application.put_env(:doctrans, :test_extraction_failure, reason)

    test "a document over the page limit is cancelled rather than retried", %{path: path} do
      document = document_fixture()

      # Every attempt reaches the same answer, so retrying only burns the
      # document's remaining attempts and re-occupies the single extraction slot.
      fail_with({:pdf_too_many_pages, [pages: 9999, limit: 1000]})

      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{
                 "document_id" => document.id,
                 "file_path" => path
               })

      # The reason arrives wrapped by the processor, so the cancellation has to
      # recognise the nested failure rather than the wrapper.
      assert names_failure?(reason, :pdf_too_many_pages)
    end

    test "a missing poppler install is cancelled rather than retried", %{path: path} do
      document = document_fixture()

      fail_with({:poppler_not_found, [command: "pdftoppm"]})

      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{
                 "document_id" => document.id,
                 "file_path" => path
               })

      assert names_failure?(reason, :poppler_not_found)
    end

    test "a timeout is still retried", %{path: path} do
      document = document_fixture()

      fail_with(:pdf_command_timeout)

      assert {:error, {:pdf_extraction_failed, [reason: :pdf_command_timeout]}} =
               perform_job(DocumentExtractionJob, %{
                 "document_id" => document.id,
                 "file_path" => path
               })
    end

    defp names_failure?(reason, tag) when is_atom(reason), do: reason == tag

    defp names_failure?({name, bindings}, tag) when is_list(bindings) do
      name == tag or names_failure?(Keyword.get(bindings, :reason, :none), tag)
    end

    test "a missing LibreOffice is cancelled rather than retried" do
      document = document_fixture(%{original_filename: "report.docx"})

      upload_dir = Doctrans.Documents.document_upload_dir(document.id)
      File.mkdir_p!(upload_dir)
      File.write!(Path.join(upload_dir, "original.docx"), "fake docx content")
      on_exit(fn -> File.rm_rf!(upload_dir) end)

      original_converter = Application.fetch_env(:doctrans, :document_converter_module)
      Application.put_env(:doctrans, :document_converter_module, MissingConverterStub)

      on_exit(fn -> restore_env(:document_converter_module, original_converter) end)

      # No number of retries installs LibreOffice, and each one re-occupies the
      # single extraction slot to reach the same answer.
      assert {:cancel, reason} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})

      assert names_failure?(reason, :soffice_not_found)
    end

    defp names_failure?(_reason, _tag), do: false

    # Putting `nil` back is not the same as the key never having been set: the
    # callers read these with a module default, which an explicit nil defeats.
    defp restore_env(key, {:ok, value}), do: Application.put_env(:doctrans, key, value)
    defp restore_env(key, :error), do: Application.delete_env(:doctrans, key)
  end

  describe "perform/1 with file_path" do
    test "reports a missing source and publishes the document error" do
      document = document_fixture()
      Topics.subscribe_document(document.id)

      assert {:error, :document_file_not_found} =
               perform_job(DocumentExtractionJob, %{
                 "document_id" => document.id,
                 "file_path" => "/nonexistent/path.pdf"
               })

      saved = Documents.get_document!(document.id)
      assert saved.status == "error"
      assert saved.error_message == ":document_file_not_found"
      assert_received {:document_updated, %{id: id, status: "error"}}
      assert id == document.id
      assert Documents.list_pages(document.id) == []
    end
  end

  describe "perform/1 with a file_path from another storage root" do
    test "extracts from the retained original under the current root" do
      document = document_fixture()
      document_source_fixture(document)

      # A job queued before a restore carries an absolute path into the root the
      # application had then. The file is present under the root it has now, so
      # the stale arg must not be what decides the document is unreadable.
      stale_path =
        Path.join([
          System.tmp_dir!(),
          "doctrans-old-root",
          "documents",
          document.id,
          "original.pdf"
        ])

      refute File.regular?(stale_path)

      assert :ok =
               perform_job(DocumentExtractionJob, %{
                 "document_id" => document.id,
                 "file_path" => stale_path
               })

      assert_completed_extraction(document)
    end
  end

  describe "perform/1 without file_path (retry case)" do
    test "returns error when document not found" do
      fake_document_id = Uniq.UUID.uuid7()

      result = perform_job(DocumentExtractionJob, %{"document_id" => fake_document_id})
      assert {:error, :document_not_found} = result
    end

    test "returns error when document file not found" do
      document = document_fixture()

      assert {:error, :document_file_not_found} =
               perform_job(DocumentExtractionJob, %{"document_id" => document.id})
    end

    test "extracts the retained PDF when the retry has no recorded path" do
      document = document_fixture()
      pdf_path = document_source_fixture(document)

      assert :ok = perform_job(DocumentExtractionJob, %{"document_id" => document.id})
      assert_completed_extraction(document)
      assert File.regular?(pdf_path)
    end

    test "finds document with original extension when pdf doesn't exist" do
      document = document_fixture(%{original_filename: "test.docx"})

      docx_path = document_source_fixture(document, "retained office input")
      TestEnv.put_env(:document_converter_module, RetryDocumentConverterStub)

      assert :ok = perform_job(DocumentExtractionJob, %{"document_id" => document.id})
      assert_completed_extraction(document)

      pdf_path = docx_path |> Path.dirname() |> Path.join("original.pdf")
      assert File.read!(pdf_path) == "retained office input"

      assert File.read!(docx_path) == "retained office input"
    end
  end

  defp assert_completed_extraction(document) do
    saved = Documents.get_document_with_pages!(document.id)
    assert saved.status == "completed"
    assert saved.total_pages == 3
    assert Enum.map(saved.pages, & &1.page_number) == [1, 2, 3]

    for page <- saved.pages do
      assert page.extraction_status == "completed"
      assert page.translation_status == "completed"
      assert File.regular?(Path.join(Documents.uploads_dir(), page.image_path))
    end
  end
end
