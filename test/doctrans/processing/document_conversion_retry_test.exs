defmodule Doctrans.Processing.DocumentConversionRetryTest do
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.{ResumablePdfExtractorStub, RetryDocumentConverterStub}

  setup do
    for {key, module} <- [
          document_converter_module: RetryDocumentConverterStub,
          pdf_extractor_module: ResumablePdfExtractorStub
        ] do
      original = Application.fetch_env(:doctrans, key)
      Application.put_env(:doctrans, key, module)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:doctrans, key, value)
          :error -> Application.delete_env(:doctrans, key)
        end
      end)
    end

    document = document_fixture(%{original_filename: "report.docx"})
    directory = Documents.document_upload_dir(document.id)
    File.mkdir_p!(directory)
    source_path = Path.join(directory, "original.docx")
    File.write!(source_path, "original document")
    on_exit(fn -> File.rm_rf!(directory) end)
    Topics.subscribe_document(document.id)

    %{
      document: document,
      source_path: source_path,
      pdf_path: Path.join(directory, "original.pdf")
    }
  end

  test "conversion failure retains the persisted job input and a retry succeeds", context do
    Oban.Testing.with_testing_mode(:manual, fn ->
      job = persist_job(context)
      Process.put(:conversion_result, {:error, :conversion_timeout})

      assert {:error, :conversion_timeout} = DocumentExtractionJob.perform(job)
      assert File.read!(context.source_path) == "original document"
      assert Documents.get_document!(context.document.id).status == "error"
      assert_received {:document_updated, %{status: "error", error_message: message}}
      assert is_binary(message)

      Process.delete(:conversion_result)
      assert :ok = DocumentExtractionJob.perform(%{job | attempt: 2})
      assert_success(context)
      assert_received {:document_updated, %{status: "processing", error_message: nil}}
    end)
  end

  test "conversion followed by interrupted extraction can resume using the original job",
       context do
    Oban.Testing.with_testing_mode(:manual, fn ->
      job = persist_job(context)
      Process.put(:fail_pdf_page, 2)

      assert {:error, {:pdf_extraction_failed, _}} = DocumentExtractionJob.perform(job)
      assert File.exists?(context.source_path)
      assert File.exists?(context.pdf_path)
      assert [first_page] = Documents.list_pages(context.document.id)

      Process.delete(:fail_pdf_page)
      assert :ok = DocumentExtractionJob.perform(%{job | attempt: 2})
      assert_success(context)
      assert hd(Documents.list_pages(context.document.id)).id == first_page.id
    end)
  end

  test "exhausted conversion attempts publish an error and retain the source", context do
    Oban.Testing.with_testing_mode(:manual, fn ->
      job = persist_job(context)
      Process.put(:conversion_result, {:error, :conversion_timeout})

      for attempt <- 1..job.max_attempts do
        assert {:error, :conversion_timeout} =
                 DocumentExtractionJob.perform(%{job | attempt: attempt})

        assert_received {:document_updated, %{status: "error", error_message: message}}
        assert message == Documents.get_document!(context.document.id).error_message
      end

      assert File.read!(context.source_path) == "original document"
      assert Documents.get_document!(context.document.id).status == "error"
    end)
  end

  defp persist_job(context) do
    {:ok, job} =
      %{document_id: context.document.id, file_path: context.source_path}
      |> DocumentExtractionJob.new()
      |> Oban.insert()

    Repo.get!(Oban.Job, job.id)
  end

  defp assert_success(context) do
    document = Documents.get_document_with_pages!(context.document.id)
    assert document.status == "processing"
    assert document.error_message == nil
    assert document.total_pages == 3
    assert Enum.map(document.pages, & &1.page_number) == [1, 2, 3]

    jobs = all_enqueued(worker: LlmProcessingJob)

    assert Enum.sort(Enum.map(jobs, & &1.args["page_id"])) ==
             Enum.sort(Enum.map(document.pages, & &1.id))

    assert File.exists?(context.source_path)
    assert File.exists?(context.pdf_path)
  end
end
