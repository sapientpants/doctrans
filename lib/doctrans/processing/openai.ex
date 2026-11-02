defmodule Doctrans.Processing.OpenAI do
  @moduledoc """
  OpenAI-compatible API client for LLM interactions.

  Handles extraction, translation, chat, streaming and model listing against
  OpenAI-compatible API endpoints. Embeddings are `Doctrans.Search.Embedding`,
  which owns its own endpoint and fuse.

  Every request goes out under `Doctrans.Processing.RequestBounds`, which caps
  how long the endpoint may take in total and how much body it may return, and
  every response is settled by `Doctrans.Processing.ApiFailure.resolve/4`, so a
  failure is logged, classified and normalized in one place.
  """

  alias Doctrans.Config.{Inference, OpenAI}
  alias Doctrans.Processing.{ApiFailure, Prompts, RequestBounds, SSECollector}
  alias Doctrans.Resilience.CircuitBreaker

  require Logger

  @behaviour Doctrans.Processing.OpenAIBehaviour

  # The cap for a caller that states none of its own, which is extraction: a
  # page of transcribed Markdown. Translation and language detection set their
  # own below, and `Doctrans.Chat.Agent` sets its own too.
  @default_max_tokens 4096

  @impl true
  @spec extract_markdown(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def extract_markdown(image_path, opts \\ [])

  # The image path comes from internally generated PDF page records, not the client filename.
  # sobelow_skip ["Traversal.FileModule"]
  def extract_markdown(image_path, opts) when is_binary(image_path) do
    path = Path.expand(image_path)

    case File.read(path) do
      {:ok, image_data} ->
        content = build_multimodal_content(image_path, image_data)
        messages = [%{role: "user", content: content}]
        opts = with_default_model(opts, OpenAI.vision_model())
        request_body = build_request_body(Keyword.put(opts, :messages, messages))

        post_chat_completion(request_body, opts)
        |> ApiFailure.resolve(:openai_api, &parse_chat_response/1)

      {:error, reason} ->
        {:error, {:image_unreadable, [reason: reason]}}
    end
  end

  defp build_multimodal_content(image_path, image_data) do
    ext = Path.extname(image_path)

    mime_type =
      case ext do
        ".jpg" -> "image/jpeg"
        ".jpeg" -> "image/jpeg"
        ".png" -> "image/png"
        _ -> "image/png"
      end

    encoded = Base.encode64(image_data)

    [
      %{type: "text", text: Prompts.extract()},
      %{type: "image_url", image_url: %{url: "data:#{mime_type};base64,#{encoded}"}}
    ]
  end

  @impl true
  @spec chat([map()], keyword()) :: {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def chat(messages, opts \\ [])

  def chat(messages, opts) when is_list(messages) do
    request_body = build_request_body(Keyword.put(opts, :messages, messages))
    url = api_url("/v1/chat/completions")
    key = api_key()

    Logger.debug(
      "OpenAI request: url=#{redact_url(url)}, auth=#{if key, do: "<set>", else: "<none>"}, body_keys=#{inspect(Map.keys(request_body))}"
    )

    post_chat_completion(request_body, opts)
    |> ApiFailure.resolve(:openai_api, &parse_chat_response/1)
  end

  # One deadline and one size cap per call; Req's retries run inside it.
  defp bounds(opts),
    do: RequestBounds.new(Keyword.take(opts, [:timeout, :deadline, :max_response_bytes]))

  # The fuse is asked, never melted, here: `ApiFailure` classifies each failure
  # and melts for the ones that count.
  defp post_chat_completion(request_body, opts) do
    CircuitBreaker.call(:openai_api, fn ->
      build_base_req()
      |> RequestBounds.post(bounds(opts),
        url: api_url("/v1/chat/completions"),
        json: request_body,
        # :transient retries all methods (incl. POST) on 408/429/5xx and
        # connection errors; chat-completion POSTs are safe to replay
        retry: :transient,
        # Req follows redirects by default, and a 307/308 replays the POST
        # body at the Location host. That would send document text somewhere
        # `Doctrans.Config.Inference` never classified, breaking the privacy
        # claim the UI makes from it. An inference server has no cause to
        # redirect; if one does, fail loudly rather than silently re-target.
        redirect: false
      )
    end)
  end

  # Fail closed: a non-streaming completion must explicitly finish normally.
  # Require the OpenAI-compatible "stop" marker; absent/null markers cannot
  # establish that the output is complete.
  defp parse_chat_response(%{"choices" => [%{"message" => message} = choice | _]})
       when is_map(message) do
    with "stop" <- Map.get(choice, "finish_reason"),
         content when is_binary(content) <- Map.get(message, "content"),
         {:ok, result} <- clean_response(content) do
      {:ok, result}
    else
      _ -> {:error, :incomplete_output}
    end
  end

  defp parse_chat_response(_body), do: {:error, :invalid_api_response}

  @impl true
  @spec chat_stream([map()], (String.t() -> any()), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def chat_stream(messages, on_delta, opts \\ [])

  def chat_stream(messages, on_delta, opts) when is_list(messages) and is_function(on_delta, 1) do
    CircuitBreaker.call(:openai_api, fn -> do_chat_stream(messages, on_delta, opts) end)
  end

  defp do_chat_stream(messages, on_delta, opts) do
    collector = SSECollector.new(on_delta)

    build_base_req()
    |> RequestBounds.post(bounds(opts),
      url: api_url("/v1/chat/completions"),
      json: build_request_body(opts ++ [messages: messages, stream: true]),
      retry: :transient,
      # See post_chat_completion/2: a redirect would replay the document
      # text at an endpoint the privacy copy never accounted for.
      redirect: false,
      collect: collect_sse(collector)
    )
    |> ApiFailure.resolve(:openai_api, &collected_content(&1, collector))
  end

  # Each raw chunk is fed into the SSE collector (kept in resp.body), which
  # parses complete `data:` frames and invokes on_delta/1 as soon as content
  # arrives. `RequestBounds` counts the bytes and watches the clock around it.
  defp collect_sse(collector) do
    fn data, body ->
      if is_map(body),
        do: SSECollector.feed(body, data),
        else: SSECollector.feed(collector, data)
    end
  end

  # `body` holds the collector state once any chunk arrived; it is still the
  # default "" (not a map) if the stream had no data frames.
  defp collected_content(body, collector) do
    state = if is_map(body), do: body, else: collector

    content =
      state
      |> SSECollector.finish()
      |> String.trim()
      |> strip_code_fences()

    if content == "", do: {:error, :empty_response}, else: {:ok, content}
  end

  @impl true
  @spec translate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def translate(markdown, source_language, target_language, opts \\ [])

  def translate(markdown, source_language, target_language, opts)
      when is_binary(markdown) and is_binary(source_language) and is_binary(target_language) do
    prompt = Prompts.translate(markdown, source_language, target_language)
    opts = with_default_model(opts, OpenAI.translation_model())

    chat(
      [%{role: "user", content: prompt}],
      opts ++ [max_tokens: 8192, think: false]
    )
  end

  @impl true
  @spec detect_language(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def detect_language(markdown, opts \\ [])

  def detect_language(markdown, opts) when is_binary(markdown) do
    opts = with_default_model(opts, OpenAI.translation_model())

    # The answer is two letters, so the cap is two letters' worth: a tight
    # `max_tokens` is what keeps a chatty model from replying with an essay.
    # The raw reply is returned as-is -- validating it belongs to the caller.
    chat(
      [%{role: "user", content: Prompts.detect_language(markdown)}],
      opts ++ [max_tokens: 16, think: false]
    )
  end

  defp clean_response(response) do
    # Only leading, unfenced thinking blocks form the reasoning envelope.
    # Once final text starts, tags belong to the document (including code examples).
    with {:ok, content} <- strip_reasoning_prefix(String.trim(response)),
         result when result != "" <- strip_code_fences(content) do
      {:ok, result}
    else
      _ -> {:error, :incomplete_output}
    end
  end

  defp strip_reasoning_prefix(content) do
    case Regex.run(~r/\A<think>(.*?)<\/think>(.*)\z/is, content) do
      [_, reasoning, rest] ->
        if Regex.match?(~r/<\/?think>/i, reasoning) do
          {:error, :incomplete_output}
        else
          strip_reasoning_prefix(String.trim(rest))
        end

      nil ->
        if Regex.match?(~r/\A<\/?think>/i, content),
          do: {:error, :incomplete_output},
          else: {:ok, content}
    end
  end

  # The model list only ever backs a modal a user is waiting in front of, so it
  # gets a tighter per-attempt budget than the processing calls.
  @list_models_timeout 5_000

  # Asks the `:openai_api` fuse like every other call on that endpoint; a blown
  # fuse answers `{:error, :circuit_open}` without a request. A failure here is
  # never counted against the fuse either: see `ApiFailure.handle/3` on
  # `melt: false`.
  @impl true
  @spec list_models() :: {:ok, [String.t()]} | {:error, Doctrans.Errors.reason()}
  def list_models do
    CircuitBreaker.call(:openai_api, &do_list_models/0)
  end

  defp do_list_models do
    build_base_req()
    |> RequestBounds.get(RequestBounds.new(timeout: @list_models_timeout),
      url: api_url("/v1/models"),
      retry: :safe_transient
    )
    |> ApiFailure.resolve(:openai_api, &parse_list_models_response/1, melt: false)
  end

  defp parse_list_models_response(%{"data" => models}) when is_list(models) do
    {:ok, Enum.map(models, & &1["id"])}
  end

  defp parse_list_models_response(_body), do: {:error, :invalid_api_response}

  # Private helpers

  defp api_url(path) do
    "#{OpenAI.base_url()}/#{String.trim_leading(path, "/")}"
  end

  # The base URL is operator-supplied and may carry credentials. Req redacts its
  # own auth header, but these URLs are logged before Req ever sees them, and dev
  # logs at :debug. `Doctrans.Config.Inference` owns the redaction because it
  # renders the same URLs into the privacy copy; one rule, one place.
  defp redact_url(url), do: Inference.redact_url(url)

  defp api_key, do: OpenAI.api_key()

  # No key, no header: an absent credential is not an empty one.
  defp build_base_req do
    case api_key() do
      nil -> Req.new()
      key -> Req.new(headers: [{"authorization", "Bearer #{key}"}])
    end
  end

  defp build_request_body(options) do
    model = Keyword.get(options, :model) || OpenAI.chat_model()
    max_tokens = Keyword.get(options, :max_tokens, @default_max_tokens)
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

  # Strip markdown code fences that LLMs sometimes wrap their output in
  @spec strip_code_fences(String.t()) :: String.t()
  def strip_code_fences(text) do
    text
    |> String.replace(~r/\A```[^\n]*\n/, "")
    |> String.replace(~r/\n?```\s*\z/, "")
    |> String.trim()
  end
end
