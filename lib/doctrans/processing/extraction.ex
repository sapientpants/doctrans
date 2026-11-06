defmodule Doctrans.Processing.Extraction do
  @moduledoc """
  Extraction, the first step of a run: the stored source is converted to PDF
  when it is not one already, rendered into page images, and every page is
  queued for the model stages.

  Pages are rendered progressively -- each page record exists before the next
  page is rendered -- so the viewer sees the page count early and the first
  thumbnail as soon as there is one. A retry reuses the pages and images an
  earlier attempt stored and queues only the processing still owed.

  The document's transitions during this step are made here and nowhere else:
  `Doctrans.Documents.Lifecycle.begin_extraction/1` as the run is picked up,
  `fail/2` for whatever stops the run before its pages exist -- a missing
  source, a conversion or a render failure -- and `begin_processing/1` with
  `settle/1` once every page is rendered and queued.
  `Doctrans.Jobs.DocumentExtractionJob` is the adapter between Oban and
  `run/1`: it decides whether the job still names the document's current run,
  and what Oban does with a failure.

  Cancellation is not a concern here: `Doctrans.Processing.Cancellation`
  cancels the job, and a run the document has moved on from is fenced by
  `Doctrans.Processing.Run`.
  """

  require Logger

  alias Doctrans.Config.PdfExtraction
  alias Doctrans.Deps
  alias Doctrans.Documents
  alias Doctrans.Documents.{Formats, Layout, Lifecycle, Topics}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.Run

  # A run the document has moved on from, or a document that settled while its
  # job waited, is not this call's to act on: nothing more is written, and the
  # caller is done.
  @not_ours [:obsolete_run, :already_settled]

  @doc """
  Runs extraction for `document` under the run it holds.

  Answers `:ok` once every page is rendered and queued, and `:ok` as well when
  the document turns out not to be this call's to act on -- its run replaced,
  or settled, since the document was loaded -- in which case nothing is
  written. Answers `{:error, reason}` after recording the failure on the
  document through `Lifecycle.fail/2`; `reason` is what
  `Doctrans.Resilience.ErrorClassifier` classifies and the web tier renders.
  """
  @spec run(Documents.Document.t()) :: :ok | {:error, Doctrans.Errors.reason()}
  def run(%Documents.Document{} = document) do
    result =
      with {:ok, source_path} <- locate_source(document),
           {:ok, document} <- Lifecycle.begin_extraction(document),
           {:ok, pdf_path} <- to_pdf(document, source_path) do
        render_pages(document, pdf_path)
      end

    conclude(document, result)
  end

  defp conclude(_document, :ok), do: :ok

  defp conclude(document, {:error, reason}) when reason in @not_ours do
    Logger.info("Extraction of document #{document.id} is not this run's to act on: #{reason}")
    :ok
  end

  defp conclude(document, {:error, reason}) do
    Logger.error("Extraction failed for document #{document.id}: #{inspect(reason)}")
    _ = Lifecycle.fail(document, reason)
    {:error, reason}
  end

  # `Run.source_path/1` is nil for a document whose extension is not a supported
  # source format, which is reported like a source that is not there.
  defp locate_source(document) do
    path = Run.source_path(document)

    if path && File.regular?(path),
      do: {:ok, path},
      else: {:error, :document_file_not_found}
  end

  defp to_pdf(document, source_path) do
    if Formats.extension(source_path) == ".pdf",
      do: {:ok, source_path},
      else: convert(document, source_path)
  end

  # The source is the stored original, whose extension passed validation at
  # upload; the output directory is derived from persisted UUIDs. The source is
  # kept for the job's next attempt or for a later reprocess.
  # sobelow_skip ["Traversal.FileModule"]
  defp convert(document, source_path) do
    output_dir = Run.output_dir(document)
    File.mkdir_p!(output_dir)

    Logger.info("Converting document #{document.id} to PDF")
    Deps.document_converter().convert_to_pdf(source_path, output_dir)
  end

  # The pages directory is built from persisted document and run UUIDs with a
  # fixed suffix.
  # sobelow_skip ["Traversal.FileModule"]
  defp render_pages(document, pdf_path) do
    Logger.info("Extracting pages from PDF for document #{document.id}")

    pages_dir = Run.pages_dir(document)
    File.mkdir_p!(pages_dir)

    # One budget for the whole document, so the per-page deadlines cannot add up
    # past the job that contains them: without it a long document reaches Oban's
    # timeout instead of failing cleanly with its finished pages preserved.
    deadline = System.monotonic_time(:millisecond) + PdfExtraction.job_timeout()

    with {:ok, page_count} <- Deps.pdf_extractor().get_page_count(pdf_path),
         {:ok, document} <- set_total_pages(document, page_count),
         :ok <- render_progressively(document, pdf_path, pages_dir, page_count, deadline) do
      Logger.info("Extracted #{page_count} pages for document #{document.id}")
      finish(document)
    else
      # A fence refusal is already the caller's answer; a render failure is
      # wrapped so the diagnostic says which step the run stopped at.
      {:error, reason} when reason in @not_ours -> {:error, reason}
      {:error, reason} -> {:error, {:pdf_extraction_failed, [reason: reason]}}
    end
  end

  # The page count is announced as soon as it is known, so the viewer can show
  # progress before the first page lands.
  defp set_total_pages(document, page_count) do
    with {:ok, updated} <- Documents.set_total_pages(document, page_count) do
      _ = Topics.broadcast_document_updated(updated)
      {:ok, updated}
    end
  end

  defp render_progressively(document, pdf_path, pages_dir, page_count, deadline) do
    Enum.reduce_while(1..page_count, :ok, fn page_number, :ok ->
      case render_and_queue_page(document, pdf_path, pages_dir, page_number, deadline) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Every page is rendered and queued, so the document is processing; pages
  # saved by an earlier attempt may even have settled it already.
  defp finish(document) do
    with :ok <- Lifecycle.begin_processing(document) do
      case Lifecycle.settle(document) do
        {:error, _} = error -> error
        _verdict -> :ok
      end
    end
  end

  defp render_and_queue_page(document, pdf_path, pages_dir, page_number, deadline) do
    with {:ok, page} <- ensure_page(document, pdf_path, pages_dir, page_number, deadline) do
      Run.with_current(document, fn current -> queue_page(page, current) end)
    end
  end

  defp queue_page(%{extraction_status: "completed", translation_status: "completed"}, _document),
    do: :ok

  defp queue_page(page, document) do
    Logger.info("Queueing page #{page.page_number} for LLM processing")

    # Oban uniqueness preserves any active job, including its retry state.
    with {:ok, _job} <- LlmProcessingJob.enqueue_page(page, Run.model_opts(document)) do
      :ok
    end
  end

  # A page whose image an earlier attempt stored is reused as it is.
  defp ensure_page(document, pdf_path, pages_dir, page_number, deadline) do
    page = Documents.get_page_by_number(document.id, page_number)

    if page && is_binary(page.image_path) && File.regular?(Layout.absolute(page.image_path)) do
      {:ok, page}
    else
      render_and_save_page(document, page, pdf_path, pages_dir, page_number, deadline)
    end
  end

  defp render_and_save_page(document, page, pdf_path, pages_dir, page_number, deadline) do
    with {:ok, image_path} <-
           Deps.pdf_extractor().extract_page(pdf_path, pages_dir, page_number, deadline: deadline) do
      attrs = %{page_number: page_number, image_path: Layout.relative(image_path)}
      save_page(document, page, attrs)
    end
  end

  defp save_page(document, page, attrs) do
    with {:ok, saved} <-
           Run.with_current(document, fn current -> write_page(current, page, attrs) end) do
      # Announced as each page lands, for progressive viewer updates.
      Topics.broadcast_page_updated(saved)
      {:ok, saved}
    end
  end

  defp write_page(document, nil, attrs), do: Documents.create_page(document, attrs)
  defp write_page(_document, page, attrs), do: Documents.update_page(page, attrs)
end
