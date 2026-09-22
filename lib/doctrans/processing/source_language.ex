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

  import Ecto.Query

  require Logger

  alias Doctrans.Documents.{Document, Topics}
  alias Doctrans.Languages
  alias Doctrans.Repo

  # Detection reads the opening of a page, not the page. Telling German from
  # Dutch does not need the whole of either, and a bounded sample keeps the call
  # as cheap on a dense page as on a title page.
  @sample_limit 2_000

  # A model asked for a language code answers "de", but also "de.", "German
  # (de)" or a whole sentence about it, so the reply is read for two-letter runs
  # rather than taken at its word.
  @code_pattern ~r/\b[a-z]{2}\b/

  @fallback_language "de"

  @doc """
  The language `document` is written in, detecting and storing one when needed.

  A language already on the document is returned unchanged and costs no model
  call. Otherwise the opening of `markdown` is sent for detection, the answer is
  written to the document row, and the value the row ends up holding is what
  comes back. That is not always the value this call detected: pages of one
  document run concurrently, and the first of them to store a language wins for
  all of them.
  """
  @spec resolve(Document.t(), String.t() | nil) :: String.t()
  def resolve(%Document{source_language: language}, _markdown) when is_binary(language),
    do: language

  def resolve(%Document{} = document, markdown) do
    markdown
    |> sample()
    |> detect()
    |> store(document)
  end

  # Allow OpenAI module to be configured for testing
  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end

  defp sample(markdown) when is_binary(markdown), do: String.slice(markdown, 0, @sample_limit)
  defp sample(_markdown), do: ""

  # A page that is blank, or an extraction that produced only whitespace, says
  # nothing about the language. Asking anyway spends a call to learn that.
  defp detect(sample) do
    if String.trim(sample) == "", do: fallback(), else: ask_model(sample)
  end

  defp ask_model(sample) do
    case openai_module().detect_language(sample, []) do
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

  # Pages of one document translate concurrently, so two of them can find the
  # column NULL and both detect. The write is conditional on it still being
  # NULL, so exactly one lands; the row is then read back and the value it holds
  # -- the winner's, which may not be ours -- is what every page translates
  # from, so a document is never half translated from one language and half
  # from another.
  #
  # No row lock is taken around the model call on purpose. Holding one across a
  # multi-second inference request would stall every other page of the document
  # behind it. A duplicate detection call is cheap; a held lock is not.
  defp store(language, document) do
    {claimed, _} =
      from(d in Document, where: d.id == ^document.id and is_nil(d.source_language))
      |> Repo.update_all(set: [source_language: language, updated_at: now()])

    stored = Repo.get(Document, document.id)
    announce(claimed, stored)

    (stored && stored.source_language) || language
  end

  # Only the write that won announces the change, so that the document page
  # shows a detected language without a refresh. A page that lost the race would
  # only be re-broadcasting what the winner already sent.
  defp announce(0, _document), do: :ok
  defp announce(_claimed, nil), do: :ok
  defp announce(_claimed, document), do: Topics.broadcast_document_updated(document)

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp fallback do
    Application.get_env(:doctrans, :defaults, [])[:source_language] || @fallback_language
  end
end
