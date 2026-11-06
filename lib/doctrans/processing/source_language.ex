defmodule Doctrans.Processing.SourceLanguage do
  @moduledoc """
  Answers what language a document is written in.

  A document's source language is decided once. If the uploader picked one, it
  stands; otherwise the first page that needs it detects it from its own
  markdown and records it on the document row, and every page of that document
  translates from that one answer. A language already on the row is never
  re-decided, which is what keeps retrying a page reproducible.

  `config :doctrans, :defaults, source_language: ...` no longer chooses anything
  for anyone. Its only remaining role is to say what gets recorded when
  detection cannot tell us -- a page with nothing on it, an unusable reply, a
  failed call.
  """

  require Logger

  alias Doctrans.Deps
  alias Doctrans.Documents
  alias Doctrans.Documents.Document
  alias Doctrans.Languages

  # Detection reads the opening of a page, not the page. Telling German from
  # Dutch does not need the whole of either, and a bounded sample keeps the call
  # as cheap on a dense page as on a title page.
  @sample_limit 2_000

  # A model asked for a language code answers "de", but also "de.", "German
  # (de)" or a whole sentence about it, so the reply is read for two-letter runs
  # rather than taken at its word.
  @code_pattern ~r/\b[a-z]{2}\b/

  # The fallback recorded when detection learns nothing; `config :doctrans,
  # :defaults, source_language:` overrides it.
  @fallback_language "de"

  @doc """
  The language `document` is written in, detecting and storing one when needed.

  A language already on the document is returned unchanged and costs no model
  call. Otherwise the opening of `markdown` is sent for detection, the answer is
  written to the document row, and the value the row ends up holding is what
  comes back. That is not always the value this call detected: pages of one
  document run concurrently, and the first of them to store a language wins for
  all of them.

  A page with nothing on it is the exception: it is answered with the fallback
  but records nothing, so a later page that does have text can still decide.
  """
  @spec resolve(Document.t(), String.t() | nil) :: String.t()
  def resolve(%Document{source_language: language}, _markdown) when is_binary(language),
    do: language

  def resolve(%Document{} = document, markdown) do
    sample = sample(markdown)

    # Nothing legible on the page means nothing was learned, so nothing is
    # recorded: storing here would stamp the fallback on the document
    # permanently on the evidence of a page that had no evidence, and no later
    # page would look again. The page itself loses nothing by it -- whitespace
    # translates to whitespace whichever language it is called.
    if blank?(sample) do
      fallback()
    else
      sample |> ask_model() |> store(document)
    end
  end

  defp sample(markdown) when is_binary(markdown), do: String.slice(markdown, 0, @sample_limit)
  defp sample(_markdown), do: ""

  # An extraction that produced only whitespace says nothing about the language,
  # and asking anyway spends a call to learn that.
  defp blank?(sample), do: String.trim(sample) == ""

  defp ask_model(sample) do
    case Deps.openai().detect_language(sample, []) do
      {:ok, reply} ->
        language_code(reply) || fallback()

      {:error, reason} ->
        Logger.warning("Language detection failed, recording the fallback: #{inspect(reason)}")
        fallback()
    end
  end

  # The reply is untrusted text, and it cannot be read by taking the first
  # two-letter run in it: "it" and "no" are ordinary English words as well as
  # Italian and Norwegian, so "It is German" would read as Italian, and "The
  # language is no" would stop at "is" and give up before reaching the answer.
  #
  # So an exact answer is taken as one, and a wordier reply is scanned for every
  # supported code it names. One distinct code is the answer however it was
  # dressed up; several means the sentence mentions more languages than it
  # identifies, and a guess between them is worth less than the fallback.
  defp language_code(reply) when is_binary(reply) do
    normalized = reply |> String.trim() |> String.downcase()

    if Languages.supported?(normalized) do
      normalized
    else
      @code_pattern
      |> Regex.scan(normalized)
      |> List.flatten()
      |> Enum.filter(&Languages.supported?/1)
      |> Enum.uniq()
      |> case do
        [code] -> code
        _none_or_ambiguous -> nil
      end
    end
  end

  defp language_code(_reply), do: nil

  # The write is `Documents.claim_source_language/2`'s: conditional on the column
  # still being empty, so of two pages detecting at once exactly one lands, and
  # the value the row holds afterwards -- the winner's, which may not be ours --
  # is what every page translates from. No row lock is taken around the model
  # call on purpose: holding one across a multi-second inference request would
  # stall every other page of the document behind it. A duplicate detection
  # call is cheap; a held lock is not.
  defp store(language, document) do
    case Documents.claim_source_language(document, language) do
      {_outcome, %Document{source_language: stored}} when is_binary(stored) -> stored
      _gone -> language
    end
  end

  defp fallback do
    Application.get_env(:doctrans, :defaults, [])[:source_language] || @fallback_language
  end
end
