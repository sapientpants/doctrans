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

  Every stage write is a transition of `Doctrans.Documents.PageLifecycle`,
  which fences it and announces it. A page reset, replaced or deleted while its
  run is in flight makes every further write to it answer
  `{:error, :obsolete_run}`; such a run ends as `:ok`, because the generation
  that superseded it now owns the work.
  """

  require Logger

  alias Doctrans.Deps
  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Lifecycle, PageLifecycle}
  alias Doctrans.Errors
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Processing.Run
  alias Doctrans.Processing.SourceLanguage
  alias Doctrans.Resilience.ErrorClassifier

  @typedoc "What the caller should do next: nothing, retry, or stop retrying."
  @type outcome :: :ok | {:error, Errors.reason()} | {:cancel, Errors.reason()}

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
  @spec process_page(Ecto.UUID.t(), keyword()) :: outcome()
  def process_page(page_id, opts \\ []) do
    generation = Keyword.fetch(opts, :generation)
    opts = Map.to_list(Run.choices(opts))

    case Documents.get_page(page_id) do
      nil ->
        {:cancel, :page_not_found}

      page ->
        if current_generation?(page, generation) do
          page |> do_process_page(opts) |> settle_obsolete_run(page)
        else
          Logger.info("Page #{page_id} has moved on to a newer generation, skipping it")
          :ok
        end
    end
  end

  # A job that names no generation acts for whatever the page holds now.
  defp current_generation?(_page, :error), do: true

  defp current_generation?(page, {:ok, generation}),
    do: Run.current?(page, generation: generation)

  # Every page write is a `PageLifecycle` transition, which answers
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
  # lifecycle fences the check against that page's revision and generation,
  # and a row re-read here would only ever be compared against itself. The
  # translation writes in between cannot invalidate it: `content_revision`
  # advances on an `original_markdown` change or an extraction leaving
  # "completed", and `processing_generation` only on a reprocess.
  defp reconcile_document(page) do
    _ = Lifecycle.settle(page)
    :ok
  end

  # A retried or rescued Oban job may have left a stage processing or errored;
  # a stage is owed until it has completed.
  defp maybe_extract(page, opts) do
    if PageLifecycle.owed?(page, :extraction) do
      extract(page, opts)
    else
      Logger.debug("Skipping extraction for page #{page.page_number}, already completed")
      :ok
    end
  end

  defp maybe_translate(page, opts) do
    cond do
      not (PageLifecycle.done?(page, :extraction) and PageLifecycle.owed?(page, :translation)) ->
        :ok

      is_binary(page.original_markdown) and page.original_markdown != "" ->
        translate(page, opts)

      true ->
        # No content to translate: the stage completes with an empty translation.
        Logger.warning(
          "Page #{page.page_number} has no content to translate, marking as completed"
        )

        with {:ok, _page} <- PageLifecycle.complete(page, :translation, %{markdown: ""}),
             do: :ok
    end
  end

  defp extract(page, opts) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    # Moves the document out of its pre-processing states (uploading, extracting,
    # queued) when its first page starts; a document already processing is left
    # alone, so every page may call it.
    with :ok <- Lifecycle.begin_processing(page),
         {:ok, page} <- PageLifecycle.begin(page, :extraction) do
      run_stage(page, :extraction, fn -> extract_markdown(page, opts) end)
    end
  end

  defp extract_markdown(page, opts) do
    image_path = Layout.absolute(page.image_path)

    case Deps.openai().extract_markdown(image_path, model_opts(opts, :extraction_model)) do
      {:ok, markdown} -> save_extraction(page, markdown, opts)
      {:error, reason} -> fail_stage(page, :extraction, reason)
    end
  end

  # A stage runs with the page already marked "processing". A crash -- a model
  # client raising, a database blip mid-write -- would otherwise leave that mark
  # behind for good: Oban retries, a deterministic failure raises again on every
  # attempt, and the page is discarded still reading "processing", neither
  # failed nor finished, for the recovery pass to re-queue on every boot.
  # Recording the failure keeps the stage truthful and lets the document settle
  # on it once Oban gives up; re-raising leaves Oban's schedule to decide whether
  # the crash was transient. `Doctrans.Search.Indexer` does the same for indexing.
  defp run_stage(page, stage, fun) do
    fun.()
  catch
    kind, reason ->
      Logger.error(
        "#{stage_name(stage)} crashed for page #{page.page_number}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      _ = PageLifecycle.fail(page, stage)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp save_extraction(page, markdown, opts) do
    product = %{markdown: markdown, model: opts[:extraction_model]}

    with {:ok, page} <- PageLifecycle.complete(page, :extraction, product) do
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

    with {:ok, page} <- PageLifecycle.begin(page, :translation),
         {:ok, document} <- fetch_document(page) do
      run_stage(page, :translation, fn -> translate_markdown(page, document, opts) end)
    end
  end

  defp translate_markdown(page, document, opts) do
    source_language = SourceLanguage.resolve(document, page.original_markdown)

    case Deps.openai().translate(
           page.original_markdown,
           source_language,
           document.target_language,
           model_opts(opts, :translation_model)
         ) do
      {:ok, translated} -> save_translation(page, translated, opts)
      {:error, reason} -> fail_stage(page, :translation, reason)
    end
  end

  defp save_translation(page, translated, opts) do
    product = %{markdown: translated, model: opts[:translation_model]}

    with {:ok, _page} <- PageLifecycle.complete(page, :translation, product), do: :ok
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
  @spec fail_stage(Documents.Page.t(), PageLifecycle.stage(), term()) ::
          {:error, Errors.reason()} | {:cancel, Errors.reason()}
  defp fail_stage(page, stage, reason) do
    with {:ok, page} <- PageLifecycle.fail(page, stage) do
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

  defp failure_code(:extraction), do: :page_extraction_failed
  defp failure_code(:translation), do: :page_translation_failed

  defp stage_name(:extraction), do: "Extraction"
  defp stage_name(:translation), do: "Translation"
end
