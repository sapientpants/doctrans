defmodule Doctrans.Processing.OpenAI do
  @moduledoc """
  OpenAI-compatible API client for LLM interactions.

  Handles extraction, translation, chat, streaming, embedding, and
  model listing against OpenAI-compatible API endpoints.
  """

  alias Doctrans.Processing.SSECollector
  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.Resilience.ErrorClassifier

  require Logger

  @behaviour Doctrans.Processing.OpenAIBehaviour

  # Request timeout for API calls (300 seconds)
  @api_timeout 300_000
  @embedding_dimensions 1024

  @impl true
  def extract_markdown(image_path, opts \\ [])

  def extract_markdown(image_path, opts) when is_binary(image_path) do
    path = Path.expand(image_path)

    case File.read(path) do
      {:ok, image_data} ->
        content = build_multimodal_content(image_path, image_data, opts)
        messages = [%{role: "user", content: content}]
        opts = with_default_model(opts, vision_model_default())
        request_body = build_request_body(Keyword.put(opts, :messages, messages))

        post_chat_completion(request_body, opts)
        |> resolve_extract_response(:openai_api)

      {:error, reason} ->
        {:error, "Could not read image file: #{inspect(reason)}"}
    end
  end

  defp resolve_extract_response({:ok, %Req.Response{status: 200, body: body}}, fuse) do
    case parse_chat_response(body) do
      {:ok, markdown} ->
        result = markdown |> String.trim() |> strip_code_fences()

        if result == "" do
          {:error, "Model returned empty response for image"}
        else
          {:ok, result}
        end

      {:error, _} = error ->
        handle_api_error(fuse, error)
    end
  end

  defp resolve_extract_response({:ok, %Req.Response{status: status} = resp}, fuse) do
    handle_api_error(fuse, {:http_status, status, resp})
  end

  defp resolve_extract_response({:error, reason}, fuse) do
    handle_api_error(fuse, reason)
  end

  defp build_multimodal_content(image_path, image_data, opts) do
    ext = Path.extname(image_path)

    mime_type =
      case ext do
        ".jpg" -> "image/jpeg"
        ".jpeg" -> "image/jpeg"
        ".png" -> "image/png"
        _ -> "image/png"
      end

    encoded = Base.encode64(image_data)

    text = build_extract_prompt(opts)

    [
      %{type: "text", text: text},
      %{type: "image_url", image_url: %{url: "data:#{mime_type};base64,#{encoded}"}}
    ]
  end

  defp build_extract_prompt(_opts) do
    "Extract all text and formatting from this image as clean Markdown. Include all headings, paragraphs, lists, tables, and other formatting elements exactly as they appear. Do not omit or summarize any content."
  end

  @impl true
  def chat(messages, opts \\ [])

  def chat(messages, opts) when is_list(messages) do
    request_body = build_request_body(Keyword.put(opts, :messages, messages))
    fuse = :openai_api
    url = api_url("/v1/chat/completions")
    key = api_key()

    headers =
      case key do
        nil -> []
        k -> [{"authorization", "Bearer #{k}"}]
      end

    Logger.debug(
      "OpenAI request: url=#{url}, headers=#{inspect(headers)}, body_keys=#{inspect(Map.keys(request_body))}"
    )

    post_chat_completion(request_body, opts)
    |> resolve_chat_response(fuse)
  end

  defp resolve_chat_response({:ok, %Req.Response{status: 200, body: body}}, _fuse) do
    case parse_chat_response(body) do
      {:ok, content} ->
        result = content |> String.trim() |> strip_code_fences()

        if result == "" do
          {:error, "Model returned empty response"}
        else
          {:ok, result}
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_chat_response({:ok, %Req.Response{status: status} = resp}, fuse) do
    handle_api_error(fuse, {:http_status, status, resp})
  end

  defp resolve_chat_response({:error, reason}, fuse) do
    handle_api_error(fuse, reason)
  end

  defp post_chat_completion(request_body, opts) do
    build_base_req()
    |> Req.post(
      url: api_url("/v1/chat/completions"),
      json: request_body,
      receive_timeout: Keyword.get(opts, :timeout, @api_timeout),
      # :transient retries all methods (incl. POST) on 408/429/5xx and
      # connection errors; chat-completion POSTs are safe to replay
      retry: :transient
    )
  end

  defp parse_chat_response(%{
         "choices" => [
           %{"message" => %{"content" => content}}
         ]
       })
       when is_binary(content) do
    {:ok, content}
  end

  defp parse_chat_response(%{
         "choices" => [
           %{"message" => message}
         ]
       })
       when is_map(message) do
    case Map.get(message, "content") do
      nil when map_size(message) == 0 ->
        # Empty response — check for reasoning / finish_reason
        check_for_reasoning(message)

      nil ->
        {:error, "Empty or missing response from API"}

      content ->
        {:ok, content}
    end
  end

  defp parse_chat_response(%{
         "choices" => [
           %{"finish_reason" => "length", "message" => message}
         ]
       })
       when is_map(message) do
    case Map.get(message, "content") do
      nil when map_size(message) == 0 ->
        # Check if we got reasoning content even with empty regular content
        reasoning = Map.get(message, "reasoning") || Map.get(message, "reasoning_content", "")

        case String.trim(reasoning) do
          "" -> {:error, "API returned empty response (possibly truncated)"}
          _reasoning -> {:ok, reasoning}
        end

      content when is_binary(content) and content != "" ->
        {:ok, content}

      _ ->
        {:error, "Empty or missing response from API"}
    end
  end

  defp parse_chat_response(%{"choices" => choices})
       when is_list(choices) and length(choices) > 1 do
    # Multiple choices: use the first one
    parse_chat_response(%{"choices" => [Enum.at(choices, 0)]})
  end

  defp parse_chat_response(_body), do: {:error, "Invalid response format from API"}

  defp check_for_reasoning(message) do
    reasoning = Map.get(message, "reasoning") || Map.get(message, "reasoning_content", "")

    case String.trim(to_string(reasoning)) do
      "" -> {:error, "Empty or missing response from API"}
      content -> {:ok, content}
    end
  end

  @impl true
  def chat_stream(messages, on_delta, opts \\ [])

  def chat_stream(messages, on_delta, opts) when is_list(messages) and is_function(on_delta, 1) do
    request_body = build_request_body(opts ++ [messages: messages, stream: true])
    fuse = :openai_api
    collector = SSECollector.new(on_delta)

    # Stream the response body chunk by chunk: each raw chunk is fed into the
    # SSE collector (kept in resp.body), which parses complete `data:` frames
    # and invokes on_delta/1 as soon as content arrives.
    into = fn
      {:data, data}, {req, resp} ->
        state =
          if is_map(resp.body),
            do: SSECollector.feed(resp.body, data),
            else: SSECollector.feed(collector, data)

        {:cont, {req, %{resp | body: state}}}
    end

    case build_base_req()
         |> Req.post(
           url: api_url("/v1/chat/completions"),
           json: request_body,
           receive_timeout: Keyword.get(opts, :timeout, @api_timeout),
           retry: :transient,
           into: into
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        # resp.body holds the collector state once any chunk arrived; it is
        # still the default "" (not a map) if the stream had no data frames.
        state = if is_map(resp.body), do: resp.body, else: collector

        content =
          state
          |> SSECollector.finish()
          |> String.trim()
          |> strip_code_fences()

        if content == "" do
          {:error, "Model returned empty response"}
        else
          {:ok, content}
        end

      {:ok, %Req.Response{} = resp} ->
        handle_api_error(fuse, {:http_status, resp.status, resp})

      {:error, reason} ->
        handle_api_error(fuse, reason)
    end
  end

  @impl true
  def translate(markdown, source_language, target_language, opts \\ [])

  def translate(markdown, source_language, target_language, opts)
      when is_binary(markdown) and is_binary(source_language) and is_binary(target_language) do
    prompt = build_translate_prompt(markdown, source_language, target_language)
    opts = with_default_model(opts, translation_model_default())

    case chat(
           [%{role: "user", content: prompt}],
           opts ++ [max_tokens: 8192, think: false]
         ) do
      {:ok, response} ->
        # Strip potential thinking tags from the response
        {:ok, clean_response(response)}

      {:error, _reason} = error ->
        error
    end
  end

  defp build_translate_prompt(markdown, source_language, target_language) do
    """
    Translate the following text from #{source_language} to #{target_language}.

    Return ONLY the translated text. Do NOT include any explanations, notes, or
    metadata. Preserve all formatting, headers, lists, tables, and structure
    exactly as it appears in the original. Maintain the same language style
    (formal/informal) as the source.

    Text to translate:

    #{markdown}
    """
  end

  defp clean_response(response) do
    # Remove any thinking blocks that may be in the response, then strip code fences
    response
    |> String.replace(~r/\<think\>[\s\S]*?<\/think\>/i, "")
    |> String.trim()
    |> strip_code_fences()
  end

  @impl true
  def available? do
    case build_base_req() |> Req.get(url: api_url("/v1/models")) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def list_models do
    fuse = :openai_api

    case build_base_req()
         |> Req.get(url: api_url("/v1/models"), retry: :safe_transient) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_list_models_response(body)

      {:ok, %Req.Response{status: status} = resp} ->
        handle_api_error(fuse, {:http_status, status, resp})

      {:error, reason} ->
        handle_api_error(fuse, reason)
    end
  end

  defp parse_list_models_response(%{
         "data" => models
       })
       when is_list(models) do
    names = Enum.map(models, & &1["id"])
    {:ok, names}
  end

  defp parse_list_models_response(%{"data" => [_]} = body) do
    parse_list_models_response(%{"data" => body["data"]})
  end

  defp parse_list_models_response(_body), do: {:error, "Invalid response format from API"}

  def embed(text, opts \\ [])

  def embed(nil, _opts), do: {:ok, nil}
  def embed("", _opts), do: {:ok, nil}

  def embed(text, opts) when is_binary(text) do
    config = embed_config()
    model = Keyword.get(opts, :model) || config[:model] || model(opts)
    timeout = Keyword.get(opts, :timeout) || config[:timeout] || 120_000
    fuse = :embedding_api

    Logger.debug(
      "Embedding POST #{embed_url("/v1/embeddings")}, model: #{model}, api_key: #{if(embed_api_key(), do: "<set>", else: "<none>")}"
    )

    request = %{model: model, input: text}

    case build_embed_base_req()
         |> Req.post(
           url: embed_url("/v1/embeddings"),
           json: request,
           receive_timeout: timeout,
           # Embedding POSTs are idempotent; replay them on transient failures
           retry: :transient
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_embed_response(body)

      {:ok, %Req.Response{status: status} = resp} ->
        handle_api_error(fuse, {:http_status, status, resp})

      {:error, reason} ->
        handle_api_error(fuse, reason)
    end
  end

  defp parse_embed_response(%{
         "data" => [%{"embedding" => embedding}]
       })
       when is_list(embedding) do
    if length(embedding) >= @embedding_dimensions do
      # Truncate to @embedding_dimensions for Matryoshka models that output
      # more dimensions than we store (e.g., 4096 -> 1024)
      {:ok, Pgvector.new(Enum.take(embedding, @embedding_dimensions))}
    else
      {:error,
       "OpenAI embedding too short: expected at least #{@embedding_dimensions} dimensions, got #{length(embedding)}"}
    end
  end

  defp parse_embed_response(_body), do: {:error, "Invalid embedding response from API"}

  defp model(opts) do
    Keyword.get_lazy(opts, :model, fn ->
      Application.get_env(:doctrans, :openai, [])[:chat_model] ||
        Application.get_env(:doctrans, :openai, [])[:vision_model]
    end)
  end

  # Private helpers

  defp openai_config do
    Application.get_env(:doctrans, :openai, [])
  end

  defp api_url(path) do
    "#{base_url()}/#{String.trim_leading(path, "/")}"
  end

  defp base_url do
    openai_config()[:base_url] || "http://localhost:8000"
  end

  defp api_key do
    openai_config()[:api_key]
  end

  defp build_base_req do
    case api_key() do
      nil -> Req.new()
      key -> Req.new(headers: [{"authorization", "Bearer #{key}"}])
    end
  end

  defp embed_config do
    Application.get_env(:doctrans, :embedding, [])
  end

  defp embed_url(path) do
    "#{embed_base_url()}/#{String.trim_leading(path, "/")}"
  end

  defp embed_base_url do
    embed_config()[:base_url] || api_url("")
  end

  defp embed_api_key do
    embed_config()[:api_key]
  end

  defp build_embed_base_req do
    case embed_api_key() do
      nil -> Req.new()
      key -> Req.new(headers: [{"authorization", "Bearer #{key}"}])
    end
  end

  defp build_request_body(options) do
    model = Keyword.get(options, :model) || default_model()
    max_tokens = Keyword.get(options, :max_tokens, default_max_tokens())
    messages = Keyword.fetch!(options, :messages)
    stream = Keyword.get(options, :stream, false)
    think = Keyword.get(options, :think, true)

    base = %{
      model: model,
      messages: messages,
      max_tokens: max_tokens
    }

    # Only send enable_thinking when it's false (default is true / not sent)
    body =
      if think do
        base
      else
        Map.put(base, "enable_thinking", false)
      end

    if stream do
      Map.put(body, "stream", true)
    else
      body
    end
  end

  defp default_model do
    openai_config()[:chat_model] || openai_config()[:vision_model]
  end

  # Extraction requires image understanding, so prefer the vision model
  # (matching the Ollama backend behaviour).
  defp vision_model_default do
    openai_config()[:vision_model] || openai_config()[:chat_model]
  end

  # Translation uses the dedicated translation model when configured.
  defp translation_model_default do
    openai_config()[:translation_model] || openai_config()[:chat_model]
  end

  defp with_default_model(opts, default) do
    if Keyword.has_key?(opts, :model) do
      opts
    else
      Keyword.put(opts, :model, default)
    end
  end

  defp default_max_tokens do
    # Larger context for chat, smaller for extraction/translation
    4096
  end

  defp handle_api_error(fuse, reason) do
    normalized = normalize_reason(reason)
    classification = ErrorClassifier.classify(normalized)

    if classification == :retryable do
      # Only transient/5xx/transport failures count against the circuit
      # breaker; a single 401 or bad request must not push it toward blown.
      CircuitBreaker.melt(fuse, reason)
    else
      Logger.debug(
        "Not melting fuse #{to_string(fuse)} for #{classification} error: #{inspect(reason)}"
      )
    end

    Logger.error("API call failed (#{classification}): #{inspect(reason)}")
    {:error, "API call failed: #{inspect(reason)}"}
  end

  # ErrorClassifier keys HTTP failures as {:http_error, status}, so map our
  # internal {:http_status, status, resp} tuple onto that shape.
  defp normalize_reason({:http_status, status, _resp}), do: {:http_error, status}

  defp normalize_reason(reason), do: reason

  # Strip markdown code fences that LLMs sometimes wrap their output in
  def strip_code_fences(text) do
    text
    |> String.replace(~r/\A```[^\n]*\n/, "")
    |> String.replace(~r/\n?```\s*\z/, "")
    |> String.trim()
  end
end
