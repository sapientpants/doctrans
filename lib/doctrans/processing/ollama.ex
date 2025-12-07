defmodule Doctrans.Processing.Ollama do
  @moduledoc """
  Client for the Ollama API.

  Provides functions for:
  - Extracting markdown from page images using a vision model (Qwen3-VL)
  - Translating markdown using a text model (Qwen3)
  """

  @behaviour Doctrans.Processing.OllamaBehaviour

  require Logger

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
        Extract all text from this image as Markdown.

        CRITICAL INSTRUCTIONS:
        - Output ONLY the extracted text in Markdown format, nothing else
        - Do NOT include any introduction like "Here is the extracted text"
        - Do NOT include any explanation or commentary
        - Preserve the original formatting including headings, lists, tables, and structure
        - Extract ALL visible text from the image
        """

        body = %{
          model: model,
          prompt: prompt,
          images: [image_base64],
          stream: false
        }

        make_request("/api/generate", body, timeout)

      {:error, reason} ->
        {:error, "Failed to read image: #{inspect(reason)}"}
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
    Translate the following text to #{target_name}.

    CRITICAL INSTRUCTIONS:
    - Output ONLY the translated text, nothing else
    - Do NOT include any introduction like "Here is the translation"
    - Do NOT include any explanation or commentary
    - Do NOT include the original text
    - Preserve all Markdown formatting exactly
    - Translate EVERY word - do not leave any text in the original language

    TEXT TO TRANSLATE:
    #{markdown}
    """

    body = %{
      model: model,
      prompt: prompt,
      stream: false
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
        {:error, "Ollama returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Failed to connect to Ollama: #{inspect(reason)}"}
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
            {:ok, String.trim(response)}

          other ->
            Logger.warning("Unexpected response format: #{inspect(other)}")
            {:error, "Unexpected response format from Ollama"}
        end

      {:ok, %{status: status, body: response_body}} ->
        error_msg = get_in(response_body, ["error"]) || inspect(response_body)
        Logger.error("Ollama request failed with status #{status}: #{error_msg}")
        {:error, "Ollama error (#{status}): #{error_msg}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("Ollama request timed out after #{timeout}ms")
        {:error, "Request timed out"}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp ollama_config do
    Application.get_env(:doctrans, :ollama, [])
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
