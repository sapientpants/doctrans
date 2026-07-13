defmodule Doctrans.Chat.LineParser do
  @moduledoc """
  Helpers for parsing labeled-line LLM responses of the form `Field: value`.

  Shared by `Doctrans.Chat.QueryExpander` and `Doctrans.Chat.Grader`, which both
  prompt the model to reply in a fixed `Label: value` line format.
  """

  @doc "Splits text into trimmed, non-empty lines."
  def lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Extracts the value following `prefix` from a list of lines, or `nil`."
  def extract_field(lines, prefix) do
    case Enum.find(lines, &String.starts_with?(&1, prefix)) do
      nil -> nil
      line -> line |> String.replace_prefix(prefix, "") |> String.trim()
    end
  end
end
