defmodule Doctrans.Processing.PageWork.Stages do
  @moduledoc """
  The two content stages of a page, each one model call: extraction from the
  page image, translation of the extracted markdown.

  This is `Doctrans.Processing.PageWork`'s implementation, not an interface of
  its own: PageWork decides which stages an attempt owes and what becomes of
  the document afterwards, and comes here for the stage itself -- begin it,
  call the model, record the product or the failure, and say whether the
  failure is worth another attempt.

  Every write is a transition of `Doctrans.Documents.PageLifecycle`, which
  fences it and announces it; a page reset, replaced or deleted mid-stage makes
  the write answer `{:error, :obsolete_run}`, which PageWork reads as the run
  belonging to the generation that superseded it.
  """

  require Logger

  alias Doctrans.Deps
  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Lifecycle, PageLifecycle}
  alias Doctrans.Errors
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Processing.SourceLanguage
  alias Doctrans.Resilience.ErrorClassifier

  @typedoc "What the attempt should do next: nothing, retry, or stop retrying."
  @type outcome :: :ok | {:error, Errors.reason()} | {:cancel, Errors.reason()}

  @doc """
  Extracts the page's markdown from its image and queues its indexing.

  Moves the document out of its pre-processing states (uploading, extracting,
  queued) when its first page starts; a document already processing is left
  alone, so every page may call it.
  """
  @spec extract(Documents.Page.t(), keyword()) :: outcome()
  def extract(page, opts) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    with :ok <- Lifecycle.begin_processing(page),
         {:ok, page} <- PageLifecycle.begin(page, :extraction) do
      run(page, :extraction, fn -> extract_markdown(page, opts) end)
    end
  end

  @doc "Translates the page's extracted markdown into the document's target language."
  @spec translate(Documents.Page.t(), keyword()) :: outcome()
  def translate(page, opts) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    with {:ok, page} <- PageLifecycle.begin(page, :translation),
         {:ok, document} <- fetch_document(page) do
      run(page, :translation, fn -> translate_markdown(page, document, opts) end)
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
  defp run(page, stage, fun) do
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

  defp extract_markdown(page, opts) do
    image_path = Layout.absolute(page.image_path)

    case Deps.openai().extract_markdown(image_path, model_opts(opts, :extraction_model)) do
      {:ok, markdown} -> save_extraction(page, markdown, opts)
      {:error, reason} -> fail_stage(page, :extraction, reason)
    end
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

  # Marks the stage failed and tells the caller whether to try again. An open
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
