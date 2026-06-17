defmodule Doctrans.Processing.LlmUtils do
  @moduledoc """
  Shared utilities for LLM provider modules.
  """

  @doc """
  Strips markdown code fences that LLMs sometimes wrap their output in.
  """
  def strip_code_fences(text) do
    text
    |> String.replace(~r/\A```[^\n]*\n/, "")
    |> String.replace(~r/\n?```\s*\z/, "")
    |> String.trim()
  end

  @doc """
  Returns the human-readable name for a language code.
  """
  def language_name(code) do
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
