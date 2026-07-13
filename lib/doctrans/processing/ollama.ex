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

  # Context window for chat/streaming. Larger than extraction/translation because
  # the agent accumulates retrieved chunks across turns plus conversation history.
  @chat_num_ctx 32_768

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  @doc """
  Extracts markdown text from an image using the vision model.

  ## Options

  - `:model` - Override the default vision model
  - `:timeout` - Override the default timeout
  """
  def extract_markdown(image_path), do: extract_markdown(image_path, [])

  def extract_markdown(image_path, opts) do
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
          # Vision models in the Qwen3 family are thinking-enabled by default.
          # OCR/extraction gains nothing from chain-of-thought, and reasoning can
          # exhaust the num_predict budget before any text reaches the `response`
          # field, yielding an empty extraction. Disable it for this task.
          think: false,
          options: %{
            num_ctx: 16_384,
            num_predict: 8_192
          }
        }

        make_request("/api/generate", body, timeout)

      {:error, reason} ->
        {:error, dgettext("errors", "Failed to read image: %{reason}", reason: inspect(reason))}
    end
  end

  @doc """
  Translates markdown text from the source language to the target language.

  Uses the TranslateGemma prompt format with the /api/chat endpoint.

  ## Options

  - `:model` - Override the default text model
  - `:timeout` - Override the default timeout
  """
  def translate(markdown, source_language, target_language),
    do: translate(markdown, source_language, target_language, [])

  def translate(markdown, source_language, target_language, opts) do
    config = ollama_config()
    model = Keyword.get(opts, :model, config[:translation_model])
    timeout = Keyword.get(opts, :timeout, config[:timeout])

    source_name = language_name(source_language)
    target_name = language_name(target_language)

    Logger.info("Translating from #{source_name} to #{target_name} using #{model}")

    prompt =
      "You are a professional #{source_name} (#{source_language}) to #{target_name} (#{target_language}) translator. " <>
        "Your goal is to accurately convey the meaning and nuances of the original #{source_name} text " <>
        "while adhering to #{target_name} grammar, vocabulary, and cultural sensitivities.\n" <>
        "Produce only the #{target_name} translation, without any additional explanations or commentary. " <>
        "Please translate the following #{source_name} text into #{target_name}:\n\n\n" <>
        markdown

    body = %{
      model: model,
      messages: [%{role: "user", content: prompt}],
      stream: false,
      # Translation is a direct transformation, not a reasoning task. Thinking adds
      # latency and risks burning the num_predict budget before the translation is
      # emitted (same empty-response failure as extraction). Keep it off.
      think: false,
      options: %{
        num_ctx: 16_384,
        num_predict: 8_192
      }
    }

    make_chat_request("/api/chat", body, timeout)
  end

  @doc """
  Sends a chat completion request to Ollama.

  Uses the /api/chat endpoint for multi-turn conversations.

  ## Parameters

  - `messages` - List of message maps with `:role` and `:content` keys.
    Roles can be "system", "user", or "assistant".
  - `opts` - Options (see below)

  ## Options

  - `:model` - Override the default text model
  - `:timeout` - Override the default timeout (default: 120_000 for chat)

  ## Returns

  - `{:ok, response_text}` on success
  - `{:error, reason}` on failure

  ## Examples

      messages = [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "What is 2+2?"}
      ]
      {:ok, response} = Ollama.chat(messages)
  """
  def chat(messages, opts \\ []) do
    config = ollama_config()
    model = Keyword.get(opts, :model, config[:chat_model])
    # Use shorter timeout for chat (2 minutes) for better UX
    timeout = Keyword.get(opts, :timeout, 120_000)
    num_predict = Keyword.get(opts, :num_predict, 4_096)
    # Thinking is on by default for the Qwen3 chat model. Structured helper calls
    # (query expansion, grading) pass `think: false` so their small num_predict
    # budget is not consumed by reasoning, which yields an empty response.
    think = Keyword.get(opts, :think, true)

    Logger.info("Sending chat request with #{length(messages)} messages using #{model}")

    body = %{
      model: model,
      messages: messages,
      stream: false,
      think: think,
      options: %{
        num_ctx: @chat_num_ctx,
        num_predict: num_predict
      }
    }

    make_chat_request("/api/chat", body, timeout)
  end

  @doc """
  Streams a chat completion from Ollama, invoking `on_delta` for each text chunk.

  Uses the /api/chat endpoint with `stream: true`. Thinking is disabled so only
  the answer text is streamed (matching extraction/translation). `on_delta` is a
  1-arity function called with each content delta (a binary) as it arrives.

  ## Parameters

  - `messages` - List of message maps with `:role` and `:content` keys
  - `on_delta` - Function invoked with each content delta binary
  - `opts` - Options (`:model`, `:timeout`, `:num_predict`)

  ## Returns

  - `{:ok, full_text}` with the complete accumulated response on success
  - `{:error, reason}` on failure
  """
  def chat_stream(messages, on_delta, opts \\ []) when is_function(on_delta, 1) do
    config = ollama_config()
    model = Keyword.get(opts, :model, config[:chat_model])
    timeout = Keyword.get(opts, :timeout, 120_000)
    num_predict = Keyword.get(opts, :num_predict, 4_096)

    Logger.info("Streaming chat request with #{length(messages)} messages using #{model}")

    body = %{
      model: model,
      messages: messages,
      stream: true,
      # Answer generation is not a reasoning task for our purposes; hiding the
      # chain-of-thought keeps streaming snappy and the output clean.
      think: false,
      options: %{
        num_ctx: @chat_num_ctx,
        num_predict: num_predict
      }
    }

    make_streaming_request("/api/chat", body, on_delta, timeout)
  end

  defp make_streaming_request(path, body, on_delta, timeout) do
    alias Doctrans.Resilience.CircuitBreaker

    CircuitBreaker.call(:ollama_api, fn ->
      do_make_streaming_request(path, body, on_delta, timeout)
    end)
  end

  defp do_make_streaming_request(path, body, on_delta, timeout) do
    config = ollama_config()
    url = "#{config[:base_url]}#{path}"

    Logger.info(
      "Ollama streaming chat request: model=#{body[:model]}, messages=#{length(body[:messages])}"
    )

    url
    |> Req.post(json: body, receive_timeout: timeout, into: stream_collector(on_delta))
    |> handle_stream_response(on_delta, timeout)
  end

  # Builds the Req `:into` collector that parses NDJSON chunks, forwards content
  # deltas, and accumulates buffer/full-text state in the response's private map.
  defp stream_collector(on_delta) do
    fn {:data, data}, {req, resp} ->
      buffer = (resp.private[:ollama_buffer] || "") <> data
      {lines, rest} = take_complete_lines(buffer)
      acc = consume_stream_lines(lines, resp.private[:ollama_full] || "", on_delta)

      resp =
        resp
        |> Req.Response.put_private(:ollama_buffer, rest)
        |> Req.Response.put_private(:ollama_full, acc)

      {:cont, {req, resp}}
    end
  end

  defp handle_stream_response({:ok, %{status: 200} = resp}, on_delta, _timeout) do
    # Flush any trailing buffered line (in case the stream did not end with "\n")
    leftover = resp.private[:ollama_buffer] || ""
    acc = consume_stream_lines([leftover], resp.private[:ollama_full] || "", on_delta)
    result = acc |> String.trim() |> strip_code_fences()

    if result == "" do
      Logger.warning("Ollama streaming chat returned empty response")

      {:error,
       dgettext("errors", "Model returned empty response while processing %{subject}",
         subject: "the request"
       )}
    else
      Logger.debug("Ollama streaming chat returned #{String.length(result)} chars")
      {:ok, result}
    end
  end

  defp handle_stream_response({:ok, %{status: status, body: response_body}}, _on_delta, _timeout) do
    error_msg = get_in(response_body, ["error"]) || inspect(response_body)
    Logger.error("Ollama streaming chat failed with status #{status}: #{error_msg}")

    {:error,
     dgettext("errors", "Ollama error (%{status}): %{error}", status: status, error: error_msg)}
  end

  defp handle_stream_response({:error, %Req.TransportError{reason: :timeout}}, _on_delta, timeout) do
    Logger.error("Ollama streaming chat timed out after #{timeout}ms")
    {:error, dgettext("errors", "Request timed out")}
  end

  defp handle_stream_response({:error, reason}, _on_delta, _timeout) do
    Logger.error("Ollama streaming chat failed: #{inspect(reason)}")
    {:error, dgettext("errors", "Request failed: %{reason}", reason: inspect(reason))}
  end

  # Splits a buffer into complete lines and a trailing remainder (text after the
  # last newline, which may be an incomplete JSON object spanning chunks).
  defp take_complete_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end

  # Decodes each NDJSON line, forwards content deltas via on_delta, and returns
  # the accumulated full text.
  defp consume_stream_lines(lines, acc, on_delta) do
    Enum.reduce(lines, acc, fn line, acc ->
      case decode_stream_line(line) do
        {:delta, delta} ->
          on_delta.(delta)
          acc <> delta

        :skip ->
          acc
      end
    end)
  end

  defp decode_stream_line(line) do
    case String.trim(line) do
      "" ->
        :skip

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{"message" => %{"content" => content}}}
          when is_binary(content) and content != "" ->
            {:delta, content}

          _ ->
            :skip
        end
    end
  end

  defp make_chat_request(path, body, timeout) do
    alias Doctrans.Resilience.CircuitBreaker

    CircuitBreaker.call(:ollama_api, fn ->
      do_make_chat_request(path, body, timeout)
    end)
  end

  defp do_make_chat_request(path, body, timeout) do
    config = ollama_config()
    url = "#{config[:base_url]}#{path}"

    Logger.info("Ollama chat request: model=#{body[:model]}, messages=#{length(body[:messages])}")

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        case response_body do
          %{"message" => %{"content" => content}} ->
            result = content |> String.trim() |> strip_code_fences()

            if result == "" do
              empty_response_error(response_body, "the request")
            else
              Logger.debug("Ollama chat returned #{String.length(result)} chars")
              {:ok, result}
            end

          other ->
            Logger.warning("Unexpected chat response format: #{inspect(other)}")
            {:error, dgettext("errors", "Unexpected response format from Ollama")}
        end

      {:ok, %{status: status, body: response_body}} ->
        error_msg = get_in(response_body, ["error"]) || inspect(response_body)
        Logger.error("Ollama chat request failed with status #{status}: #{error_msg}")

        {:error,
         dgettext("errors", "Ollama error (%{status}): %{error}",
           status: status,
           error: error_msg
         )}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("Ollama chat request timed out after #{timeout}ms")
        {:error, dgettext("errors", "Request timed out")}

      {:error, reason} ->
        Logger.error("Ollama chat request failed: #{inspect(reason)}")
        {:error, dgettext("errors", "Request failed: %{reason}", reason: inspect(reason))}
    end
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
    alias Doctrans.Resilience.CircuitBreaker

    CircuitBreaker.call(:ollama_api, fn ->
      do_make_request(path, body, timeout)
    end)
  end

  defp do_make_request(path, body, timeout) do
    config = ollama_config()
    url = "#{config[:base_url]}#{path}"

    log_request(body)

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        # Extract the response text from Ollama's response
        Logger.info("Ollama raw response keys: #{inspect(Map.keys(response_body))}")

        case response_body do
          %{"response" => response} ->
            Logger.info(
              "Ollama response length: #{String.length(response)}, first 500 chars: #{String.slice(response, 0, 500)}"
            )

            result = response |> String.trim() |> strip_code_fences()

            if result == "" do
              empty_response_error(response_body, "the image")
            else
              Logger.debug("Ollama returned #{String.length(result)} chars")
              {:ok, result}
            end

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

  # Builds a descriptive error for an empty model response. Qwen3 models are
  # thinking-enabled; when reasoning consumes the entire num_predict budget the
  # text field comes back empty with done_reason "length". Surface that case
  # explicitly so it is distinguishable from a genuine processing failure.
  # `thinking` lives at the top level for /api/generate and under "message" for
  # /api/chat.
  defp empty_response_error(response_body, subject) do
    done_reason = response_body["done_reason"]

    thinking =
      response_body["thinking"] || get_in(response_body, ["message", "thinking"]) || ""

    thinking_chars = String.length(thinking)

    Logger.warning(
      "Ollama returned empty response (done_reason=#{inspect(done_reason)}, thinking_chars=#{thinking_chars})"
    )

    if done_reason == "length" and thinking_chars > 0 do
      {:error,
       dgettext(
         "errors",
         "Model used its entire output budget while thinking and returned no text. Disable thinking for this model or increase num_predict."
       )}
    else
      {:error,
       dgettext("errors", "Model returned empty response while processing %{subject}",
         subject: subject
       )}
    end
  end

  defp ollama_config do
    Application.get_env(:doctrans, :ollama, [])
  end

  defp log_request(body) do
    image_bytes =
      case body[:images] do
        [img | _] -> byte_size(img)
        _ -> 0
      end

    Logger.info(
      "Ollama request: model=#{body[:model]}, prompt_length=#{String.length(body[:prompt] || "")}, image_base64_bytes=#{image_bytes}"
    )
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
      "ko" => "Korean",
      "da" => "Danish",
      "no" => "Norwegian",
      "sv" => "Swedish"
    }

    Map.get(languages, code, code)
  end
end
