defmodule Doctrans.Processing.Prompts do
  @moduledoc """
  The wording the model is given, in one place.

  Extraction, translation and language detection each ask the model for
  something narrow, and each asks in a way that was tuned against real replies.
  Keeping the text together means the instructions can be read and revised as a
  set rather than hunted down one call site at a time.
  """

  alias Doctrans.Languages

  @doc "Asks the model to transcribe a page image as Markdown."
  @spec extract(keyword()) :: String.t()
  def extract(_opts) do
    "Extract all text and formatting from this image as clean Markdown. Include all headings, paragraphs, lists, tables, and other formatting elements exactly as they appear. Do not omit or summarize any content."
  end

  @doc "Asks the model to translate `markdown` between two languages, preserving structure."
  @spec translate(String.t(), String.t(), String.t()) :: String.t()
  def translate(markdown, source_language, target_language) do
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

  @doc "Asks the model for the ISO 639-1 code of the language `markdown` is written in."
  @spec detect_language(String.t()) :: String.t()
  def detect_language(markdown) do
    """
    Identify the language the following document is written in.

    Answer with ONLY the ISO 639-1 two-letter code. No explanation, no notes, no
    punctuation, no code fence - just the two letters.

    The answer must be one of these codes: #{Enum.join(Languages.supported(), ", ")}.
    If the document is in none of them, answer with the closest one.

    Judge the language the text IS WRITTEN IN, not a language it mentions,
    quotes, or discusses. A document about the French language written in German
    is de.

    Document:

    #{markdown}
    """
  end
end
