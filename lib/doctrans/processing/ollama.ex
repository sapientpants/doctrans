defmodule Doctrans.Processing.Ollama do
  @moduledoc """
  Client for the Ollama API.

  Provides functions for:
  - Extracting markdown from page images using a vision model (Qwen3-VL)
  - Translating markdown using a text model (Qwen3)

  ## I18n Note

  This module runs in background GenServer processes (document processing workers),
  not in the web request process. Since Gettext locales are process-specific, error
  messages from this module will use the default locale, not the user's browser locale.
  This is acceptable as these errors are primarily logged and displayed as system status.
  """

  @behaviour Doctrans.Processing.OllamaBehaviour

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  @doc """
  Extracts markdown text from an image using the vision model.

  ## Options

  - `:model` - Override the default vision model
  - `:timeout` - Override the default timeout
  """
  def extract_markdown(image_path, opts \\ []) do
    config = ollama_config()
    model = Keyword.get(opts, :model, config[:vision_model])
    timeout = Keyword.get(opts, :timeout, config[:timeout])

    Logger.info("Extracting markdown from #{image_path} using #{model}")

    # Read and encode the image as base64
    case File.read(image_path) do
      {:ok, image_data} ->
        image_base64 = Base.encode64(image_data)

        prompt = """
        Extract ALL text from this document image as Markdown, preserving the visual formatting as closely as possible.

        CRITICAL - EXTRACT EVERYTHING:
        - Extract text from EVERY region: main content, headers, footers, margins, sidebars
        - Include ALL captions, labels, footnotes, and annotations
        - Extract text from within figures, diagrams, and charts
        - Do NOT skip any text, no matter how small or seemingly unimportant
        - Read the ENTIRE page from top to bottom, left to right

        FORMATTING - MIRROR THE SOURCE LAYOUT:
        - The Markdown output should visually resemble the original document when rendered
        - Use # ## ### for headings - match the visual hierarchy (larger/bolder = higher level)
        - Use **bold** for any bold or heavy-weight text
        - Use *italic* for any italicized or slanted text
        - Use `code` for monospace, typewriter, or code-styled text
        - Use > for blockquotes, pull quotes, or visually indented sections
        - Use - or * for bullet lists, 1. 2. 3. for numbered lists
        - Preserve nested list indentation exactly as shown
        - Use | for tables - maintain column alignment with |---|
        - Use --- for horizontal lines or section dividers
        - Preserve paragraph spacing - use blank lines where the source has visual breaks
        - Keep line breaks within addresses, poems, signatures, or multi-line formatted blocks
        - Preserve any special formatting like centered text or right-aligned content

        OUTPUT RULES:
        - Output ONLY the extracted Markdown, nothing else
        - Do NOT wrap output in code fences (```)
        - Do NOT add introductions like "Here is the extracted text"
        - Do NOT add explanations or commentary
        - Do NOT describe images - extract the TEXT within them
        """

        body = %{
          model: model,
          prompt: prompt,
          images: [image_base64],
          stream: false,
          options: %{
            # Allow up to 16K tokens for extraction - tables of contents and dense
            # pages can have a lot of text. Default limits may truncate output.
            num_predict: 16_384
          }
        }

        make_request("/api/generate", body, timeout)

      {:error, reason} ->
        {:error, dgettext("errors", "Failed to read image: %{reason}", reason: inspect(reason))}
    end
  end

  @doc """
  Translates markdown text to the target language.

  The source language is automatically detected by the model.

  ## Options

  - `:model` - Override the default text model
  - `:timeout` - Override the default timeout
  """
  def translate(markdown, target_language, opts \\ []) do
    config = ollama_config()
    model = Keyword.get(opts, :model, config[:text_model])
    timeout = Keyword.get(opts, :timeout, config[:timeout])

    target_name = language_name(target_language)

    Logger.info("Translating to #{target_name} using #{model}")

    prompt = """
    Translate the following Markdown text to #{target_name}, preserving ALL formatting exactly.

    FORMATTING PRESERVATION - CRITICAL:
    - Keep ALL Markdown syntax unchanged: #, ##, ###, **bold**, *italic*, `code`, etc.
    - Preserve the EXACT same heading levels (# vs ## vs ###)
    - Keep **bold** markers around translated bold text
    - Keep *italic* markers around translated italic text
    - Preserve table structure with | and |---| exactly
    - Keep list markers (-, *, 1., 2.) and indentation
    - Preserve > blockquote markers
    - Keep blank lines and paragraph breaks in the same places
    - Preserve horizontal rules (---)
    - Keep any line breaks within formatted blocks

    TRANSLATION RULES:
    - Translate ALL text content to #{target_name}
    - Do NOT leave any words in the original language
    - Keep proper nouns, brand names, and technical terms as appropriate for the target language

    OUTPUT RULES:
    - Output ONLY the translated Markdown, nothing else
    - Do NOT wrap output in code fences (```)
    - Do NOT include introductions like "Here is the translation"
    - Do NOT include explanations or commentary
    - Do NOT include the original text

    TEXT TO TRANSLATE:
    #{markdown}
    """

    body = %{
      model: model,
      prompt: prompt,
      stream: false,
      options: %{
        # Allow up to 16K tokens for translation - must handle full page content
        num_predict: 16_384
      }
    }

    make_request("/api/generate", body, timeout)
  end

  @doc """
  Checks if Ollama is running and accessible.
  """
  def available? do
    config = ollama_config()
    url = "#{config[:base_url]}/api/tags"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Lists available models from Ollama.
  """
  def list_models do
    config = ollama_config()
    url = "#{config[:base_url]}/api/tags"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        models = get_in(body, ["models"]) || []
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, %{status: status, body: body}} ->
        {:error,
         dgettext("errors", "Ollama returned status %{status}: %{body}",
           status: status,
           body: inspect(body)
         )}

      {:error, reason} ->
        {:error,
         dgettext("errors", "Failed to connect to Ollama: %{reason}", reason: inspect(reason))}
    end
  end

  # Private functions

  defp make_request(path, body, timeout) do
    config = ollama_config()
    url = "#{config[:base_url]}#{path}"

    Logger.debug("Making request to #{url}")

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        # Extract the response text from Ollama's response
        case response_body do
          %{"response" => response} ->
            {:ok, response |> String.trim() |> strip_code_fences()}

          other ->
            Logger.warning("Unexpected response format: #{inspect(other)}")
            {:error, dgettext("errors", "Unexpected response format from Ollama")}
        end

      {:ok, %{status: status, body: response_body}} ->
        error_msg = get_in(response_body, ["error"]) || inspect(response_body)
        Logger.error("Ollama request failed with status #{status}: #{error_msg}")

        {:error,
         dgettext("errors", "Ollama error (%{status}): %{error}",
           status: status,
           error: error_msg
         )}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("Ollama request timed out after #{timeout}ms")
        {:error, dgettext("errors", "Request timed out")}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, dgettext("errors", "Request failed: %{reason}", reason: inspect(reason))}
    end
  end

  defp ollama_config do
    Application.get_env(:doctrans, :ollama, [])
  end

  # Strip markdown code fences that LLMs sometimes wrap their output in
  def strip_code_fences(text) do
    text
    |> String.replace(~r/\A```[^\n]*\n/, "")
    |> String.replace(~r/\n?```\s*\z/, "")
    |> String.trim()
  end

  defp language_name(code) do
    languages = %{
      "de" => "German",
      "en" => "English",
      "fr" => "French",
      "es" => "Spanish",
      "it" => "Italian",
      "pt" => "Portuguese",
      "nl" => "Dutch",
      "pl" => "Polish",
      "ru" => "Russian",
      "zh" => "Chinese",
      "ja" => "Japanese",
      "ko" => "Korean"
    }

    Map.get(languages, code, code)
  end
end
