defmodule Doctrans.Processing.LlmProcessor do
  @moduledoc """
  Handles LLM-based processing of individual pages.

  Performs markdown extraction and translation using an OpenAI-compatible API models.
  Each page is processed independently: first extraction, then translation.

  This module adds no retry loop of its own: a transient failure is reported to
  the caller — `Doctrans.Jobs.LlmProcessingJob`, which owns the retry schedule —
  and a failure that retrying cannot fix is reported as `{:cancel, reason}` so it
  is not retried at all. A stage that fails is marked errored on the page, which
  is what lets the next attempt resume at that stage rather than from the start.

  Errors remain structured across background processes. The web layer translates
  them using the viewing process's locale.

  A page reset, replaced or deleted while its run is in flight makes every
  further write to it answer `{:error, :obsolete_run}`; such a run ends as `:ok`,
  because the generation that superseded it now owns the work.
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Errors
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Processing.Completion
  alias Doctrans.Processing.Run
  alias Doctrans.Processing.SourceLanguage
  alias Doctrans.Resilience.ErrorClassifier

  @typedoc "What the caller should do next: nothing, retry, or stop retrying."
  @type outcome :: :ok | {:error, Errors.reason()} | {:cancel, Errors.reason()}

  @typep stage :: :extraction | :translation

  # Allow OpenAI module to be configured for testing
  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end

  @doc """
  Processes a single page through the LLM pipeline (extraction + translation).

  Returns `:ok`, `{:error, reason}` when the failed stage is worth another
  attempt, or `{:cancel, reason}` when it is not — a permanent model error, or
  a page that no longer exists.

  ## Options

  - `:extraction_model` - Override the default extraction model
  - `:translation_model` - Override the default translation model
  - `:generation` - The page generation this run was queued for; a page that
    has moved on is skipped
  """
  @spec process_page(Ecto.UUID.t(), MapSet.t(Ecto.UUID.t()), keyword()) :: outcome()
  def process_page(page_id, cancelled_documents, opts \\ []) do
    generation = Keyword.fetch(opts, :generation)
    opts = Map.to_list(Run.choices(opts))

    case Documents.get_page(page_id) do
      nil ->
        {:cancel, :page_not_found}

      page ->
        if MapSet.member?(cancelled_documents, page.document_id) ||
             (generation != :error && generation != {:ok, page.processing_generation}) do
          Logger.info("Document #{page.document_id} was cancelled, skipping page #{page_id}")
          :ok
        else
          page |> do_process_page(opts) |> settle_obsolete_run(page)
        end
    end
  end

  # Every page write goes through `Run.with_page/2`, which answers
  # `{:error, :obsolete_run}` once the page has been reset, replaced or deleted
  # under this run. The work belongs to the generation that superseded it, so
  # the run ends as a success rather than as a retry of work it no longer owns.
  defp settle_obsolete_run({:error, :obsolete_run}, page) do
    Logger.info("Page #{page.id} changed mid-run, leaving it to its current generation")
    :ok
  end

  defp settle_obsolete_run(outcome, _page), do: outcome

  defp do_process_page(page, opts) do
    with :ok <- maybe_extract(page, opts),
         {:ok, extracted} <- reload_page(page),
         :ok <- maybe_translate(extracted, opts) do
      reconcile_document(extracted)
    end
  end

  # The row can be gone between stages: indexing is the last thing extraction
  # does, and a deletion that lands there takes the page with it.
  defp reload_page(page) do
    case Documents.get_page(page.id) do
      nil -> {:error, :obsolete_run}
      current -> {:ok, current}
    end
  end

  # The final page write and the document's completion are separate
  # transactions, so a crash between them leaves a processing document whose
  # pages are all saved. A replay skips both stages and would return `:ok`
  # without ever revisiting the document, which is why the check belongs to
  # every successful run of this job rather than to the run that happened to
  # save the last translation. Resolving it costs no model call.
  #
  # Hand over the page this run already read rather than a fresh copy. The
  # orchestrator fences the check against that page's revision and generation,
  # and a row re-read here would only ever be compared against itself. The
  # translation writes in between cannot invalidate it: `content_revision`
  # advances on an `original_markdown` change or an extraction leaving
  # "completed", and `processing_generation` only on a reprocess.
  defp reconcile_document(page) do
    _ = Completion.check_document_completion(page)
    :ok
  end

  # A retried or rescued Oban job may have left a stage processing or errored.
  defp maybe_extract(%{extraction_status: status} = page, opts)
       when status in ["pending", "processing", "error"] do
    extract(page, opts)
  end

  defp maybe_extract(%{extraction_status: status} = page, _opts) do
    Logger.debug("Skipping extraction for page #{page.page_number}, status is #{status}")
    :ok
  end

  defp maybe_translate(
         %{
           extraction_status: "completed",
           translation_status: status,
           original_markdown: markdown
         } =
           page,
         opts
       )
       when status in ["pending", "processing", "error"] and is_binary(markdown) and
              markdown != "" do
    translate(page, opts)
  end

  defp maybe_translate(
         %{extraction_status: "completed", translation_status: status} = page,
         _opts
       )
       when status in ["pending", "processing", "error"] do
    # No content to translate - mark as completed with empty translation
    Logger.warning("Page #{page.page_number} has no content to translate, marking as completed")

    with {:ok, _page} <- mark_stage(page, :translation, "completed"), do: :ok
  end

  defp maybe_translate(_page, _opts), do: :ok

  defp extract(page, opts) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    # Moves the document out of its pre-processing states (uploading, extracting,
    # queued) when its first page starts; a document already processing is left
    # alone, so every page may call it.
    with :ok <- Completion.update_document_status_to_processing(page),
         {:ok, page} <- mark_stage(page, :extraction, "processing") do
      image_path = Path.join(Documents.uploads_dir(), page.image_path)

      case openai_module().extract_markdown(image_path, model_opts(opts, :extraction_model)) do
        {:ok, markdown} -> save_extraction(page, markdown, opts)
        {:error, reason} -> fail_stage(page, :extraction, reason)
      end
    end
  end

  defp save_extraction(page, markdown, opts) do
    with {:ok, page} <-
           Documents.update_page_extraction(page, %{
             extraction_model: opts[:extraction_model],
             original_markdown: markdown,
             extraction_status: "completed"
           }) do
      Topics.broadcast_page_updated(page)
      queue_indexing(page)
      :ok
    end
  end

  # The only other thing that queues indexing is startup recovery, which runs
  # once per boot — so an enqueue lost here keeps the page out of search until
  # the next restart. That is worth a line in the log rather than a dropped result.
  defp queue_indexing(page) do
    case EmbeddingJob.enqueue_page(page) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not queue indexing for page #{page.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp translate(page, opts) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    with {:ok, page} <- mark_stage(page, :translation, "processing"),
         {:ok, document} <- fetch_document(page) do
      source_language = SourceLanguage.resolve(document, page.original_markdown)

      case openai_module().translate(
             page.original_markdown,
             source_language,
             document.target_language,
             model_opts(opts, :translation_model)
           ) do
        {:ok, translated} -> save_translation(page, translated, opts)
        {:error, reason} -> fail_stage(page, :translation, reason)
      end
    end
  end

  defp save_translation(page, translated, opts) do
    with {:ok, page} <-
           Documents.update_page_translation(page, %{
             translation_model: opts[:translation_model],
             translated_markdown: translated,
             translation_status: "completed"
           }) do
      Topics.broadcast_page_updated(page)
      :ok
    end
  end

  # A document deleted after its page was read is the same obsolete run as a
  # page replaced under it: nothing of this generation is left to write to.
  defp fetch_document(page) do
    case Documents.get_document(page.document_id) do
      nil -> {:error, :obsolete_run}
      document -> {:ok, document}
    end
  end

  defp model_opts(opts, key) do
    case Keyword.get(opts, key) do
      nil -> []
      model -> [model: model]
    end
  end

  # Marks the stage errored and tells the caller whether to try again. An open
  # circuit breaker is unclassified and so retried: the breaker closes on its
  # own, and Oban's backoff is the wait for it that this module used to sleep
  # through. A permanent error is given up on at once — every attempt would pay
  # for the same model call and get the same answer.
  @spec fail_stage(Documents.Page.t(), stage(), term()) ::
          {:error, Errors.reason()} | {:cancel, Errors.reason()}
  defp fail_stage(page, stage, reason) do
    with {:ok, page} <- mark_stage(page, stage, "error") do
      failure = {failure_code(stage), [page_number: page.page_number, reason: reason]}

      if ErrorClassifier.retryable?(reason) do
        Logger.warning(
          "#{stage_name(stage)} failed for page #{page.page_number}, leaving the retry to the job: #{inspect(reason)}"
        )

        {:error, failure}
      else
        Logger.error(
          "Permanent #{stage} error for page #{page.page_number}, not retrying: #{inspect(reason)}"
        )

        {:cancel, failure}
      end
    end
  end

  # Writes a stage status under the run guard and announces it. The guard's
  # `{:error, :obsolete_run}` is returned as is, for `process_page/3` to settle.
  @spec mark_stage(Documents.Page.t(), stage(), String.t()) ::
          {:ok, Documents.Page.t()} | {:error, Errors.reason()}
  defp mark_stage(page, stage, status) do
    with {:ok, page} <- write_stage(page, stage, status) do
      Topics.broadcast_page_updated(page)
      {:ok, page}
    end
  end

  defp write_stage(page, :extraction, status),
    do: Documents.update_page_extraction(page, %{extraction_status: status})

  defp write_stage(page, :translation, status),
    do: Documents.update_page_translation(page, %{translation_status: status})

  defp failure_code(:extraction), do: :page_extraction_failed
  defp failure_code(:translation), do: :page_translation_failed

  defp stage_name(:extraction), do: "Extraction"
  defp stage_name(:translation), do: "Translation"
end
