defmodule Doctrans.Processing.LlmProcessor do
  @moduledoc """
  Handles LLM-based processing of individual pages.

  Performs markdown extraction and translation using Ollama models.
  Each page is processed independently: first extraction, then translation.

  ## I18n Note

  This module runs in background GenServer processes (document processing pipeline),
  not in the web request process. Since Gettext locales are process-specific, error
  messages from this module will use the default locale, not the user's browser locale.
  This is acceptable as these errors are primarily logged and displayed as system status.
  """

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Documents
  alias Doctrans.Processing.DocumentOrchestrator
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

  # Allow Ollama module to be configured for testing
  defp ollama_module do
    Application.get_env(:doctrans, :ollama_module, Doctrans.Processing.Ollama)
  end

  @doc """
  Processes a single page through the LLM pipeline (extraction + translation).

  Returns `:ok` or `{:error, reason}`.

  ## Options

  - `:extraction_model` - Override the default extraction model
  - `:translation_model` - Override the default translation model
  """
  def process_page(page_id, cancelled_documents, opts \\ []) do
    case Documents.get_page(page_id) do
      nil ->
        {:error, dgettext("errors", "Page not found")}

      page ->
        if MapSet.member?(cancelled_documents, page.document_id) do
          Logger.info("Document #{page.document_id} was cancelled, skipping page #{page_id}")
          :ok
        else
          do_process_page(page, opts)
        end
    end
  end

  defp do_process_page(page, opts) do
    with :ok <- maybe_extract(page, opts),
         page <- Documents.get_page!(page.id) do
      maybe_translate(page, opts)
    end
  end

  defp maybe_extract(%{extraction_status: "pending"} = page, opts) do
    process_page_extraction(page, 0, opts)
  end

  defp maybe_extract(%{extraction_status: status} = page, _opts) do
    Logger.debug("Skipping extraction for page #{page.page_number}, status is #{status}")
    :ok
  end

  defp maybe_translate(
         %{
           extraction_status: "completed",
           translation_status: "pending",
           original_markdown: markdown
         } =
           page,
         opts
       )
       when is_binary(markdown) and markdown != "" do
    process_page_translation(page, 0, opts)
  end

  defp maybe_translate(
         %{extraction_status: "completed", translation_status: "pending"} = page,
         _opts
       ) do
    # No content to translate - mark as completed with empty translation
    Logger.warning("Page #{page.page_number} has no content to translate, marking as completed")
    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "completed"})
    Documents.broadcast_page_update(page)

    # Check if all pages are complete and mark document as completed if so
    DocumentOrchestrator.check_document_completion(page.document_id)
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
    DocumentOrchestrator.update_document_status_to_processing(page.document_id)

    {:ok, page} = Documents.update_page_extraction(page, %{extraction_status: "processing"})
    Documents.broadcast_page_update(page)

    image_path = Path.join(Documents.uploads_dir(), page.image_path)
    ollama_opts = build_extraction_opts(opts)

    case ollama_module().extract_markdown(image_path, ollama_opts) do
      {:ok, markdown} ->
        {:ok, page} =
          Documents.update_page_extraction(page, %{
            original_markdown: markdown,
            extraction_status: "completed"
          })

        Documents.broadcast_page_update(page)
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
    Documents.broadcast_page_update(page)

    {:error,
     dgettext("errors", "Page %{page_number} extraction failed: %{reason}",
       page_number: page.page_number,
       reason: inspect(reason)
     )}
  end

  defp process_page_translation(page, retry_count, opts) do
    Logger.info("Translating page #{page.page_number} of document #{page.document_id}")

    {:ok, page} = Documents.update_page_translation(page, %{translation_status: "processing"})
    Documents.broadcast_page_update(page)

    document = Documents.get_document!(page.document_id)
    ollama_opts = build_translation_opts(opts)

    case ollama_module().translate(page.original_markdown, document.target_language, ollama_opts) do
      {:ok, translated} ->
        {:ok, page} =
          Documents.update_page_translation(page, %{
            translated_markdown: translated,
            translation_status: "completed"
          })

        Documents.broadcast_page_update(page)

        # Check if all pages are complete and mark document as completed if so
        DocumentOrchestrator.check_document_completion(page.document_id)
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
    Documents.broadcast_page_update(page)

    {:error,
     dgettext("errors", "Page %{page_number} translation failed: %{reason}",
       page_number: page.page_number,
       reason: inspect(reason)
     )}
  end
end
