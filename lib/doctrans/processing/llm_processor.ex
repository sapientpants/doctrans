defmodule Doctrans.Processing.LlmProcessor do
  @moduledoc """
  Handles LLM-based processing of individual pages.

  Performs markdown extraction and translation using an OpenAI-compatible API models.
  Each page is processed independently: first extraction, then translation.

  Errors remain structured across background processes. The web layer translates
  them using the viewing process's locale.
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.DocumentOrchestrator
  alias Doctrans.Processing.Run
  alias Doctrans.Resilience.{Backoff, ErrorClassifier}
  alias Doctrans.Search.EmbeddingWorker

  @max_retries 3

  defp retry_config do
    config = Application.get_env(:doctrans, :retry, [])

    %{
      max_attempts: Keyword.get(config, :max_attempts, @max_retries),
      base_delay_ms: Keyword.get(config, :base_delay_ms, 2_000),
      max_delay_ms: Keyword.get(config, :max_delay_ms, 30_000)
    }
  end

  # Allow OpenAI module to be configured for testing
  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end

  @doc """
  Processes a single page through the LLM pipeline (extraction + translation).

  Returns `:ok` or `{:error, reason}`.

  ## Options

  - `:extraction_model` - Override the default extraction model
  - `:translation_model` - Override the default translation model
  """
  def process_page(page_id, cancelled_documents, opts \\ []) do
    generation = Keyword.fetch(opts, :generation)
    opts = Map.to_list(Run.choices(opts))

    case Documents.get_page(page_id) do
      nil ->
        {:error, :page_not_found}

      page ->
        if MapSet.member?(cancelled_documents, page.document_id) ||
             (generation != :error && generation != {:ok, page.processing_generation}) do
          Logger.info("Document #{page.document_id} was cancelled, skipping page #{page_id}")
          :ok
        else
          do_process_page(page, opts)
        end
    end
  rescue
    error in MatchError ->
      if error.term == {:error, :obsolete_run}, do: :ok, else: reraise(error, __STACKTRACE__)

    Ecto.NoResultsError ->
      :ok
  end

  defp do_process_page(page, opts) do
    with :ok <- maybe_extract(page, opts),
         page <- Documents.get_page!(page.id) do
      maybe_translate(page, opts)
    end
  end

  # A retried or rescued Oban job may have left a stage processing or errored.
  defp maybe_extract(%{extraction_status: status} = page, opts)
       when status in ["pending", "processing", "error"] do
    process_page_extraction(page, 0, opts)
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
    process_page_translation(page, 0, opts)
  end

  defp maybe_translate(
         %{extraction_status: "completed", translation_status: status} = page,
         _opts
       )
       when status in ["pending", "processing", "error"] do
    # No content to translate - mark as completed with empty translation
    Logger.warning("Page #{page.page_number} has no content to translate, marking as completed")
    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "completed"})
    Topics.broadcast_page_update(page)

    # Check if all pages are complete and mark document as completed if so
    _ = DocumentOrchestrator.check_document_completion(page)

    :ok
  end

  defp maybe_translate(_page, _opts), do: :ok

  defp process_page_extraction(page, retry_count, opts) do
    Logger.info(
      "Extracting markdown for page #{page.page_number} of document #{page.document_id}"
    )

    # Update document status to "processing" when page extraction starts (if not already processing).
    # This is safe to call for every page - DocumentOrchestrator only updates if status
    # is in a pre-processing state (uploading, extracting, queued).
    :ok = DocumentOrchestrator.update_document_status_to_processing(page)

    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "processing"})
    Topics.broadcast_page_update(page)

    image_path = Path.join(Documents.uploads_dir(), page.image_path)
    openai_opts = build_extraction_opts(opts)

    case openai_module().extract_markdown(image_path, openai_opts) do
      {:ok, markdown} ->
        {:ok, page} =
          Documents.update_page_extraction(page, %{
            extraction_model: opts[:extraction_model],
            original_markdown: markdown,
            extraction_status: "completed"
          })

        Topics.broadcast_page_update(page)
        EmbeddingWorker.generate_embedding(page.id)
        :ok

      {:error, reason} ->
        handle_extraction_error(page, reason, retry_count, opts)
    end
  end

  defp build_extraction_opts(opts) do
    case Keyword.get(opts, :extraction_model) do
      nil -> []
      model -> [model: model]
    end
  end

  defp handle_extraction_error(page, reason, retry_count, opts) do
    config = retry_config()
    classification = ErrorClassifier.classify(reason)

    cond do
      # Circuit breaker is open - don't retry
      reason == :circuit_open ->
        Logger.error("Circuit breaker open, not retrying extraction for page #{page.page_number}")
        mark_extraction_failed(page, reason)

      # Permanent error - don't retry
      classification == :permanent ->
        Logger.error(
          "Permanent error for page #{page.page_number}, not retrying: #{inspect(reason)}"
        )

        mark_extraction_failed(page, reason)

      # Retryable error and we have retries left
      retry_count < config.max_attempts ->
        delay =
          Backoff.calculate(retry_count,
            base: config.base_delay_ms,
            max: config.max_delay_ms
          )

        Logger.warning(
          "Extraction failed for page #{page.page_number}, retrying in #{delay}ms (#{retry_count + 1}/#{config.max_attempts})"
        )

        :telemetry.execute(
          [:doctrans, :retry, :attempt],
          %{count: 1, delay_ms: delay},
          %{type: :extraction, page_id: page.id, attempt: retry_count + 1}
        )

        Process.sleep(delay)
        process_page_extraction(page, retry_count + 1, opts)

      # Max retries exceeded
      true ->
        Logger.error(
          "Extraction failed for page #{page.page_number} after #{config.max_attempts} retries: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:doctrans, :retry, :exhausted],
          %{count: 1},
          %{type: :extraction, page_id: page.id}
        )

        mark_extraction_failed(page, reason)
    end
  end

  defp mark_extraction_failed(page, reason) do
    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "error"})
    Topics.broadcast_page_update(page)

    {:error, {:page_extraction_failed, [page_number: page.page_number, reason: reason]}}
  end

  defp process_page_translation(page, retry_count, opts) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "processing"})
    Topics.broadcast_page_update(page)

    document = Documents.get_document!(page.document_id)
    openai_opts = build_translation_opts(opts)

    source_language = Application.get_env(:doctrans, :defaults, [])[:source_language] || "de"

    case openai_module().translate(
           page.original_markdown,
           source_language,
           document.target_language,
           openai_opts
         ) do
      {:ok, translated} ->
        {:ok, page} =
          Documents.update_page_translation(page, %{
            translation_model: opts[:translation_model],
            translated_markdown: translated,
            translation_status: "completed"
          })

        Topics.broadcast_page_update(page)

        # Update chunk translated content
        EmbeddingWorker.update_chunk_translations(page)

        # Check if all pages are complete and mark document as completed if so
        _ = DocumentOrchestrator.check_document_completion(page)

        :ok

      {:error, reason} ->
        handle_translation_error(page, reason, retry_count, opts)
    end
  end

  defp build_translation_opts(opts) do
    case Keyword.get(opts, :translation_model) do
      nil -> []
      model -> [model: model]
    end
  end

  defp handle_translation_error(page, reason, retry_count, opts) do
    config = retry_config()
    classification = ErrorClassifier.classify(reason)

    cond do
      # Circuit breaker is open - don't retry
      reason == :circuit_open ->
        Logger.error(
          "Circuit breaker open, not retrying translation for page #{page.page_number}"
        )

        mark_translation_failed(page, reason)

      # Permanent error - don't retry
      classification == :permanent ->
        Logger.error(
          "Permanent error for page #{page.page_number}, not retrying: #{inspect(reason)}"
        )

        mark_translation_failed(page, reason)

      # Retryable error and we have retries left
      retry_count < config.max_attempts ->
        delay =
          Backoff.calculate(retry_count,
            base: config.base_delay_ms,
            max: config.max_delay_ms
          )

        Logger.warning(
          "Translation failed for page #{page.page_number}, retrying in #{delay}ms (#{retry_count + 1}/#{config.max_attempts})"
        )

        :telemetry.execute(
          [:doctrans, :retry, :attempt],
          %{count: 1, delay_ms: delay},
          %{type: :translation, page_id: page.id, attempt: retry_count + 1}
        )

        Process.sleep(delay)
        process_page_translation(page, retry_count + 1, opts)

      # Max retries exceeded
      true ->
        Logger.error(
          "Translation failed for page #{page.page_number} after #{config.max_attempts} retries: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:doctrans, :retry, :exhausted],
          %{count: 1},
          %{type: :translation, page_id: page.id}
        )

        mark_translation_failed(page, reason)
    end
  end

  defp mark_translation_failed(page, reason) do
    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "error"})
    Topics.broadcast_page_update(page)

    {:error, {:page_translation_failed, [page_number: page.page_number, reason: reason]}}
  end
end
