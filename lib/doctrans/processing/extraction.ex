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
  `run/2`: it decides whether the job still names the document's current run,
  and what Oban does with a failure.

  Cancellation is not a concern here: `Doctrans.Processing.Cancellation`
  cancels the job, and a run the document has moved on from is fenced by
  `Doctrans.Processing.Run`.
  """

  require Logger

  alias Doctrans.Config.PdfExtraction
  alias Doctrans.Deps
  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Lifecycle, Source, Topics}
  alias Doctrans.Processing.{PageWork, Run}

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

  `:deadline` is the monotonic millisecond at which the document's render
  budget -- `Doctrans.Config.PdfExtraction.job_timeout/0` -- runs out. The job
  passes the one it armed as it began, so the budget counts the conversion and
  the page count as well as the renders; a call without one starts the budget
  now.
  """
  @spec run(Documents.Document.t(), deadline: integer()) ::
          :ok | {:error, Doctrans.Errors.reason()}
  def run(%Documents.Document{} = document, opts \\ []) do
    deadline = Keyword.get_lazy(opts, :deadline, &budget_from_now/0)

    result =
      with {:ok, source_path} <- locate_source(document),
           {:ok, document} <- Lifecycle.begin_extraction(document),
           {:ok, pdf_path} <- to_pdf(document, source_path) do
        render_pages(document, pdf_path, deadline)
      end

    conclude(document, result)
  end

  defp budget_from_now, do: System.monotonic_time(:millisecond) + PdfExtraction.job_timeout()

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

  # `Source.path/1` is nil for a document whose extension is not a supported
  # source format, which is reported like a source that is not there.
  defp locate_source(document) do
    path = Source.path(document)

    if path && File.regular?(path),
      do: {:ok, path},
      else: {:error, :document_file_not_found}
  end

  defp to_pdf(document, source_path) do
    if Source.pdf?(document),
      do: {:ok, source_path},
      else: convert(document, source_path)
  end

  # The source is the stored original, whose extension passed validation at
  # upload; the output directory is derived from persisted UUIDs. The source is
  # kept for the job's next attempt or for a later reprocess.
  # sobelow_skip ["Traversal.FileModule"]
  defp convert(document, source_path) do
    output_dir = Layout.output_dir(document)
    File.mkdir_p!(output_dir)

    Logger.info("Converting document #{document.id} to PDF")
    Deps.document_converter().convert_to_pdf(source_path, output_dir)
  end

  # The pages directory is built from persisted document and run UUIDs with a
  # fixed suffix.
  # sobelow_skip ["Traversal.FileModule"]
  defp render_pages(document, pdf_path, deadline) do
    Logger.info("Extracting pages from PDF for document #{document.id}")

    pages_dir = Layout.pages_dir(document)
    File.mkdir_p!(pages_dir)

    # One budget for the whole document, so the per-page deadlines cannot add up
    # past the job that contains them: a long document fails cleanly here, with
    # its finished pages preserved, inside the wider guard Oban holds over the
    # job -- which would kill the job process without recording anything.
    with {:ok, page_count} <- Deps.pdf_extractor().get_page_count(pdf_path),
         {:ok, document} <- Documents.set_total_pages(document, page_count),
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

  # A page an active job already owns keeps that job, retry state included,
  # and a page whose stages are both complete owes nothing: either way the
  # page is accounted for.
  defp queue_page(page, document) do
    with {:ok, _queued} <- PageWork.queue(page, document, as: :fresh), do: :ok
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
