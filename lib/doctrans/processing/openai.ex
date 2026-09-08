defmodule Doctrans.Processing.OpenAI do
  @moduledoc """
  OpenAI-compatible API client for LLM interactions.

  Handles extraction, translation, chat, streaming, embedding, and
  model listing against OpenAI-compatible API endpoints.
  """

  alias Doctrans.Config.{Embedding, OpenAI}
  alias Doctrans.Processing.SSECollector
  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.Resilience.ErrorClassifier

  require Logger

  @behaviour Doctrans.Processing.OpenAIBehaviour

  @embedding_dimensions 1024

  @impl true
  @spec extract_markdown(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def extract_markdown(image_path, opts \\ [])

  def extract_markdown(image_path, opts) when is_binary(image_path) do
    path = Path.expand(image_path)

    case File.read(path) do
      {:ok, image_data} ->
        content = build_multimodal_content(image_path, image_data, opts)
        messages = [%{role: "user", content: content}]
        opts = with_default_model(opts, OpenAI.vision_model())
        request_body = build_request_body(Keyword.put(opts, :messages, messages))

        post_chat_completion(request_body, opts)
        |> resolve_extract_response(:openai_api)

      {:error, reason} ->
        {:error, {:image_unreadable, [reason: reason]}}
    end
  end

  defp resolve_extract_response({:ok, %Req.Response{status: 200, body: body}}, fuse) do
    case parse_chat_response(body) do
      {:ok, markdown} ->
        result = markdown |> String.trim() |> strip_code_fences()

        if result == "" do
          {:error, :empty_image_response}
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
  @spec chat([map()], keyword()) :: {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def chat(messages, opts \\ [])

  def chat(messages, opts) when is_list(messages) do
    request_body = build_request_body(Keyword.put(opts, :messages, messages))
    fuse = :openai_api
    url = api_url("/v1/chat/completions")
    key = api_key()

    Logger.debug(
      "OpenAI request: url=#{url}, auth=#{if key, do: "<set>", else: "<none>"}, body_keys=#{inspect(Map.keys(request_body))}"
    )

    post_chat_completion(request_body, opts)
    |> resolve_chat_response(fuse)
  end

  defp resolve_chat_response({:ok, %Req.Response{status: 200, body: body}}, _fuse) do
    case parse_chat_response(body) do
      {:ok, content} ->
        result = content |> String.trim() |> strip_code_fences()

        if result == "" do
          {:error, :empty_response}
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
      receive_timeout: Keyword.get(opts, :timeout, OpenAI.timeout()),
      # :transient retries all methods (incl. POST) on 408/429/5xx and
      # connection errors; chat-completion POSTs are safe to replay
      retry: :transient
    )
  end

  defp parse_chat_response(%{"choices" => [%{"message" => message}]})
       when is_map(message) do
    case Map.get(message, "content") do
      content when is_binary(content) and content != "" ->
        {:ok, content}

      _ ->
        # Missing or blank content — fall back to reasoning content if the
        # model produced any (e.g. truncated or thinking-only responses)
        check_for_reasoning(message)
    end
  end

  defp parse_chat_response(%{"choices" => choices})
       when is_list(choices) and length(choices) > 1 do
    # Multiple choices: use the first one
    parse_chat_response(%{"choices" => [Enum.at(choices, 0)]})
  end

  defp parse_chat_response(_body), do: {:error, :invalid_api_response}

  # Returns the trimmed reasoning content as the result, or an error when the
  # response carried no usable content at all.
  defp check_for_reasoning(message) do
    reasoning = Map.get(message, "reasoning") || Map.get(message, "reasoning_content", "")

    case String.trim(to_string(reasoning)) do
      "" -> {:error, :missing_api_response}
      content -> {:ok, content}
    end
  end

  @impl true
  @spec chat_stream([map()], (String.t() -> any()), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
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
           receive_timeout: Keyword.get(opts, :timeout, OpenAI.timeout()),
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
          {:error, :empty_response}
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
  @spec translate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def translate(markdown, source_language, target_language, opts \\ [])

  def translate(markdown, source_language, target_language, opts)
      when is_binary(markdown) and is_binary(source_language) and is_binary(target_language) do
    prompt = build_translate_prompt(markdown, source_language, target_language)
    opts = with_default_model(opts, OpenAI.translation_model())

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
  @spec available?() :: boolean()
  def available? do
    case build_base_req() |> Req.get(url: api_url("/v1/models")) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  @spec list_models() :: {:ok, [String.t()]} | {:error, Doctrans.Errors.reason()}
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

  defp parse_list_models_response(_body), do: {:error, :invalid_api_response}

  @spec embed(String.t() | nil, keyword()) ::
          {:ok, Pgvector.t() | nil} | {:error, Doctrans.Errors.reason()}
  def embed(text, opts \\ [])

  def embed(nil, _opts), do: {:ok, nil}
  def embed("", _opts), do: {:ok, nil}

  def embed(text, opts) when is_binary(text) do
    model = Keyword.get(opts, :model) || Embedding.model()
    timeout = Keyword.get(opts, :timeout) || Embedding.timeout()
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
       {:embedding_too_short, [expected: @embedding_dimensions, actual: length(embedding)]}}
    end
  end

  defp parse_embed_response(_body), do: {:error, :invalid_embedding_response}

  # Private helpers

  defp api_url(path) do
    "#{base_url()}/#{String.trim_leading(path, "/")}"
  end

  defp base_url do
    OpenAI.base_url()
  end

  defp api_key do
    OpenAI.api_key()
  end

  defp build_base_req do
    case api_key() do
      nil -> Req.new()
      key -> Req.new(headers: [{"authorization", "Bearer #{key}"}])
    end
  end

  defp embed_url(path) do
    "#{embed_base_url()}/#{String.trim_leading(path, "/")}"
  end

  defp embed_base_url do
    Embedding.base_url()
  end

  defp embed_api_key do
    Embedding.api_key()
  end

  defp build_embed_base_req do
    case embed_api_key() do
      nil -> Req.new()
      key -> Req.new(headers: [{"authorization", "Bearer #{key}"}])
    end
  end

  defp build_request_body(options) do
    model = Keyword.get(options, :model) || OpenAI.chat_model()
    max_tokens = Keyword.get(options, :max_tokens, default_max_tokens())
    messages = Keyword.fetch!(options, :messages)
    stream = Keyword.get(options, :stream, false)
    think = Keyword.get(options, :think, false)

    base = %{
      model: model,
      messages: messages,
      max_tokens: max_tokens
    }

    # Only send the thinking toggle when it's false (models default to
    # thinking on). Qwen3.x chat templates applied by oMLX only suppress
    # reasoning when `enable_thinking` is passed as a *chat template* kwarg;
    # a top-level request field is not part of the OpenAI schema and is
    # silently dropped by the server, so it must go inside
    # `chat_template_kwargs` for the template to see it.
    body =
      if think do
        base
      else
        Map.put(base, :chat_template_kwargs, %{"enable_thinking" => false})
      end

    if stream do
      Map.put(body, "stream", true)
    else
      body
    end
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
    {:error, Doctrans.Errors.normalize(normalized)}
  end

  # ErrorClassifier keys HTTP failures as {:http_error, status}, so map our
  # internal {:http_status, status, resp} tuple onto that shape.
  defp normalize_reason({:http_status, status, _resp}), do: {:http_error, status}

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)

  defp normalize_reason(reason), do: reason

  # Strip markdown code fences that LLMs sometimes wrap their output in
  @spec strip_code_fences(String.t()) :: String.t()
  def strip_code_fences(text) do
    text
    |> String.replace(~r/\A```[^\n]*\n/, "")
    |> String.replace(~r/\n?```\s*\z/, "")
    |> String.trim()
  end
end
