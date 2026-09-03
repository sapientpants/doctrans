defmodule Doctrans.Processing.OpenAIProbe do
  @moduledoc """
  Mock implementation of OpenAIBehaviour that records the options of every
  call, for tests asserting per-stage behaviour (e.g. the thinking toggle).

  Point it at a recording process with:

      Application.put_env(:doctrans, :openai_probe_pid, self())

  Each call sends `{function, opts}` to that process and returns a canned
  successful response.
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

  @impl true
  def chat(_messages, opts) do
    record(:chat, opts)
    {:ok, "probe response"}
  end

  @impl true
  def chat_stream(_messages, on_delta, opts) do
    record(:chat_stream, opts)

    response = "probe stream"

    [first, rest] = [String.slice(response, 0, 5), String.slice(response, 5..-1)]
    on_delta.(first)
    on_delta.(rest)

    {:ok, response}
  end

  @impl true
  def extract_markdown(_image_path, _opts) do
    {:ok, "# Probe markdown"}
  end

  @impl true
  def translate(_markdown, _source_language, target_language, _opts) do
    {:ok, "probe translation #{target_language}"}
  end

  @impl true
  def available?, do: true

  @impl true
  def list_models, do: {:ok, ["probe-model"]}

  @impl true
  def embed(_text, _opts), do: {:ok, List.duplicate(0.1, 1024)}

  defp record(function, opts) do
    case Application.get_env(:doctrans, :openai_probe_pid) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        send(pid, {function, opts})
    end
  end
end
