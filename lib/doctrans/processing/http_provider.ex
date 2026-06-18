defmodule Doctrans.Processing.HttpProvider do
  @moduledoc """
  Shared HTTP provider logic for Ollama and Unsloth.

  Both providers use the same API protocol (llama.cpp server), so this module
  contains the common request/response handling. Each provider module acts as
  a thin wrapper that passes its config through.
  """

  @derive {Inspect, except: [:config]}
  defstruct config_key: nil, circuit_key: nil, name: nil, config: nil

  defmodule Config do
    @moduledoc false
    defstruct config_key: nil, circuit_key: nil, name: nil
  end

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  import Doctrans.Processing.LlmUtils, only: [strip_code_fences: 1]

  @doc """
  Makes a generate request (for image extraction).
  """
  def extract_markdown(image_path, provider, opts \\ []) do
    config = provider_config(provider)
    model = Keyword.get(opts, :model, config[:vision_model])
    timeout = Keyword.get(opts, :timeout, config[:timeout])

    Logger.info("Extracting markdown from #{image_path} using #{model}")

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
          think: false,
          options: %{
            num_ctx: 16_384,
            num_predict: 8_192
          }
        }

        make_request("/api/generate", body, timeout, provider)

      {:error, reason} ->
        {:error,
         dgettext("errors", "Failed to read image: %{reason}", reason: format_error(reason))}
    end
  end

  @doc """
  Makes a translate request.
  """
  def translate(markdown, source_language, target_language, provider, opts \\ []) do
    config = provider_config(provider)
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
      think: false,
      options: %{
        num_ctx: 16_384,
        num_predict: 8_192
      }
    }

    make_chat_request("/api/chat", body, timeout, provider)
  end

  @doc """
  Makes a chat completion request.
  """
  def chat(messages, provider, opts \\ []) do
    config = provider_config(provider)
    model = Keyword.get(opts, :model, config[:chat_model])
    timeout = Keyword.get(opts, :timeout, 120_000)
    num_predict = Keyword.get(opts, :num_predict, 4_096)

    Logger.info("Sending chat request with #{length(messages)} messages using #{model}")

    body = %{
      model: model,
      messages: messages,
      stream: false,
      options: %{
        num_ctx: 16_384,
        num_predict: num_predict
      }
    }

    make_chat_request("/api/chat", body, timeout, provider)
  end

  @doc """
  Checks if the provider is running and accessible.
  """
  def available?(provider) do
    config = provider_config(provider)
    url = "#{config[:base_url]}/api/tags"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Lists available models from the provider.
  """
  def list_models(provider) do
    config = provider_config(provider)
    url = "#{config[:base_url]}/api/tags"
    name = provider.name

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        models = get_in(body, ["models"]) || []
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, %{status: status, body: body}} ->
        error_detail =
          case body["error"] do
            nil -> inspect(body)
            msg -> msg
          end

        {:error,
         dgettext("errors", "%{provider} returned status %{status}: %{body}",
           provider: name,
           status: status,
           body: error_detail
         )}

      {:error, reason} ->
        {:error,
         dgettext("errors", "Failed to connect to %{provider}: %{reason}",
           provider: name,
           reason: format_error(reason)
         )}
    end
  end

  # Private functions

  defp make_request(path, body, timeout, provider) do
    alias Doctrans.Resilience.CircuitBreaker

    CircuitBreaker.call(provider.circuit_key, fn ->
      do_make_request(path, body, timeout, provider)
    end)
  end

  defp do_make_request(path, body, timeout, provider) do
    config = provider_config(provider)
    url = "#{config[:base_url]}#{path}"
    name = provider.name

    log_request(body, name)

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        Logger.debug("#{name} raw response keys: #{inspect(Map.keys(response_body))}")

        case response_body do
          %{"response" => response} ->
            Logger.debug(
              "#{name} response length: #{String.length(response)}, first 500 chars: #{String.slice(response, 0, 500)}"
            )

            result = response |> String.trim() |> strip_code_fences()

            if result == "" do
              empty_response_error(response_body, "the image", name)
            else
              Logger.debug("#{name} returned #{String.length(result)} chars")
              {:ok, result}
            end

          other ->
            Logger.warning("Unexpected response format: #{inspect(other)}")

            {:error,
             dgettext("errors", "Unexpected response format from %{provider}", provider: name)}
        end

      {:ok, %{status: status, body: response_body}} ->
        error_msg = get_in(response_body, ["error"]) || to_string(response_body)
        Logger.error("#{name} request failed with status #{status}: #{error_msg}")

        {:error,
         dgettext("errors", "%{provider} error (%{status}): %{error}",
           provider: name,
           status: status,
           error: error_msg
         )}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("#{name} request timed out after #{timeout}ms")
        {:error, dgettext("errors", "Request timed out")}

      {:error, reason} ->
        Logger.error("#{name} request failed: #{format_error(reason)}")
        {:error, dgettext("errors", "Request failed: %{reason}", reason: format_error(reason))}
    end
  end

  defp make_chat_request(path, body, timeout, provider) do
    alias Doctrans.Resilience.CircuitBreaker

    CircuitBreaker.call(provider.circuit_key, fn ->
      do_make_chat_request(path, body, timeout, provider)
    end)
  end

  defp do_make_chat_request(path, body, timeout, provider) do
    config = provider_config(provider)
    url = "#{config[:base_url]}#{path}"
    name = provider.name

    Logger.info(
      "#{name} chat request: model=#{body[:model]}, messages=#{length(body[:messages])}"
    )

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        case response_body do
          %{"message" => %{"content" => content}} ->
            result = content |> String.trim() |> strip_code_fences()

            if result == "" do
              empty_response_error(response_body, "the request", name)
            else
              Logger.debug("#{name} chat returned #{String.length(result)} chars")
              {:ok, result}
            end

          other ->
            Logger.warning("Unexpected chat response format: #{inspect(other)}")

            {:error,
             dgettext("errors", "Unexpected response format from %{provider}", provider: name)}
        end

      {:ok, %{status: status, body: response_body}} ->
        error_msg = get_in(response_body, ["error"]) || to_string(response_body)
        Logger.error("#{name} chat request failed with status #{status}: #{error_msg}")

        {:error,
         dgettext("errors", "%{provider} error (%{status}): %{error}",
           provider: name,
           status: status,
           error: error_msg
         )}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("#{name} chat request timed out after #{timeout}ms")
        {:error, dgettext("errors", "Request timed out")}

      {:error, reason} ->
        Logger.error("#{name} chat request failed: #{format_error(reason)}")
        {:error, dgettext("errors", "Request failed: %{reason}", reason: format_error(reason))}
    end
  end

  defp empty_response_error(response_body, subject, provider_name) do
    done_reason = response_body["done_reason"]

    thinking =
      response_body["thinking"] || get_in(response_body, ["message", "thinking"]) || ""

    thinking_chars = String.length(thinking)

    Logger.warning(
      "#{provider_name} returned empty response (done_reason=#{inspect(done_reason)}, thinking_chars=#{thinking_chars})"
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

  defp provider_config(provider), do: Application.get_env(:doctrans, provider.config_key, [])

  defp log_request(body, provider_name) do
    image_bytes =
      case body[:images] do
        [img | _] -> byte_size(img)
        _ -> 0
      end

    Logger.info(
      "#{provider_name} request: model=#{body[:model]}, prompt_length=#{String.length(body[:prompt] || "")}, image_base64_bytes=#{image_bytes}"
    )
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

  @doc false
  def format_error(reason) do
    case reason do
      %struct{} when struct.__exception__ -> Exception.message(reason)
      atom when is_atom(atom) -> Atom.to_string(atom)
      string when is_binary(string) -> string
      other -> inspect(other)
    end
  end
end
