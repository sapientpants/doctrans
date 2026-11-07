defmodule Doctrans.Chat.RetrievedContext do
  @moduledoc """
  The passages a conversation keeps from `Doctrans.Chat.Retrieval` across its
  turns: the Retrieved context.

  One value, changed only through this module. Adding passages dedups them by
  identity, prefers a Page's newer text over its older, bounds what is kept by
  count and by size, and ranks the survivors by similarity. A context is only
  as fresh as the Pages it was read from: `current/1` drops every passage whose
  Page no longer holds the text it was read from, and `page_changed/2` applies
  the same test to one Page a broadcast delivered. `prompt_text/1` is the one
  rendering the model sees, and `dump/1` and `load/1` are the one stored form.

  ## Freshness

  A passage carries the `:content_revision` of its Page when it was read. The
  revision advances on extraction, not on translation, and page embeddings are
  generated as soon as extraction completes, so a whole-page passage can be read
  between the two and stored untranslated at a revision that stays current once
  the translation lands. A whole-page passage is therefore current only when its
  translation matches the Page's as well. Chunk passages never carry a
  translation, so for them the revision alone decides.
  """

  alias Doctrans.Chat.Retrieval
  alias Doctrans.Documents

  require Logger

  @typedoc "One passage as `Doctrans.Chat.Retrieval` returned it."
  @type passage :: Retrieval.result()

  @enforce_keys [:passages]
  defstruct passages: []

  @opaque t :: %__MODULE__{passages: [passage()]}

  @max_passages 16

  # Counts both markdown fields plus the page label and separator each passage
  # costs in `prompt_text/1`, so the bound holds for stored text as well as for
  # the rendered prompt. It is not a model token limit.
  @max_bytes 32_000

  @stored_fields ~w(page_id page_number chunk_index content_revision similarity original_markdown translated_markdown)a

  @doc """
  The context of a conversation that has retrieved nothing yet.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{passages: []}

  @doc """
  The passages in rank order, best first. For reading: a context changes only
  through this module.
  """
  @spec passages(t()) :: [passage()]
  def passages(%__MODULE__{passages: passages}), do: passages

  @doc """
  Adds newly retrieved passages to the context.

  Dedups by identity `{page_id, chunk_index}` (`chunk_index` is nil for a
  whole-page passage) and drops every passage superseded by a newer
  `:content_revision` of the same Page, so a reprocessed Page cannot keep
  serving its previous text. Revision wins over similarity: a higher-ranked copy
  of an older revision is obsolete, not preferable. Passages carrying no
  revision predate revision tracking and rank below any known revision.

  Within one revision, a whole-page copy carrying the Page's translation
  outranks a copy retrieved before that translation was written: writing a
  translation does not advance the revision, so similarity alone would keep
  serving the untranslated text. The surviving copy keeps the best similarity
  recorded for its identity at that revision, so preferring the translation
  never costs the Page its rank.

  The survivors are ranked by similarity and kept within #{@max_passages}
  passages and #{@max_bytes} bytes. A passage that does not fit is dropped, and
  smaller, lower-ranked passages may use the remaining budget. Drops are logged
  without document content.
  """
  @spec add(t(), [passage()]) :: t()
  def add(%__MODULE__{passages: prior}, passages) when is_list(passages) do
    ranked = rank(prior ++ passages)
    kept = fit(ranked)

    if length(kept) < length(ranked) do
      Logger.info(
        "Retrieved context budget dropped #{length(ranked) - length(kept)} passages " <>
          "(max_passages=#{@max_passages}, max_bytes=#{@max_bytes})"
      )
    end

    %__MODULE__{passages: kept}
  end

  @doc """
  Keeps only the passages that still match their Page's current text.

  Retrieved context outlives the text it was built from: a single-page
  reprocess replaces a Page's content while the context a socket holds, the
  saved context and an answer in flight still carry the previous text. A
  passage whose Page was deleted, reprocessed, or predates revision tracking
  cannot be shown to be current and is dropped, as is a whole-page passage
  whose translation no longer matches (see the module doc).
  """
  @spec current(t()) :: t()
  def current(%__MODULE__{passages: []} = context), do: context

  def current(%__MODULE__{passages: passages}) do
    pages =
      passages
      |> Enum.map(&Map.get(&1, :page_id))
      |> Documents.page_text_state()

    kept =
      Enum.filter(passages, fn passage ->
        case Map.get(pages, Map.get(passage, :page_id)) do
          nil -> false
          {revision, translation} -> current?(passage, revision, translation)
        end
      end)

    if length(kept) < length(passages) do
      Logger.info(
        "Retrieved context dropped #{length(passages) - length(kept)} passages from stale page content"
      )
    end

    %__MODULE__{passages: kept}
  end

  @doc """
  Applies `current/1`'s test to one Page an update was broadcast for, without
  reading it again.

  A socket keeps its context between turns, so a Page changed in another tab
  has to be evicted where the context is held. A passage read from another Page
  is never superseded by this one, so the whole context can be passed.
  """
  @spec page_changed(t(), Documents.Page.t()) :: t()
  def page_changed(%__MODULE__{passages: passages}, page) do
    kept =
      Enum.reject(passages, fn passage ->
        Map.get(passage, :page_id) == page.id and
          not current?(passage, page.content_revision, page.translated_markdown)
      end)

    %__MODULE__{passages: kept}
  end

  @doc """
  Drops every passage read from one of `page_ids`, whatever its state.

  For a Page whose content is being discarded: its passages would answer the
  next question from text the Document no longer holds.
  """
  @spec forget_pages(t(), [Ecto.UUID.t()]) :: t()
  def forget_pages(%__MODULE__{passages: passages}, page_ids) do
    %__MODULE__{passages: Enum.reject(passages, &(Map.get(&1, :page_id) in page_ids))}
  end

  @doc """
  The context as the model sees it.

  Passages are grouped by page number and each page section is labelled for
  citation; chunks of one page are joined in chunk order. A whole-page passage
  is rendered from its translation when it has one, a chunk always from its
  source text: saved chunk context from before translations were dropped from
  chunk retrieval can still pair a chunk with a translation it does not
  correspond to.
  """
  @spec prompt_text(t()) :: String.t()
  def prompt_text(%__MODULE__{passages: []}), do: ""

  def prompt_text(%__MODULE__{passages: passages}) do
    passages
    |> Enum.group_by(& &1.page_number)
    |> Enum.sort_by(fn {page_number, _items} -> page_number end)
    |> Enum.map(fn {page_number, items} -> page_section(page_number, items) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end

  @doc """
  The stored form of the context: one map per passage, with the fields a
  passage is restored from. `load/1` reads it back.
  """
  @spec dump(t()) :: [map()]
  def dump(%__MODULE__{passages: passages}), do: Enum.map(passages, &Map.take(&1, @stored_fields))

  @doc """
  Restores a context from rows `dump/1` wrote, as they come back from the
  database with string keys.

  The rows pass through `add/2`, so whatever was stored comes back deduped,
  ranked and within budget.
  """
  @spec load([map()]) :: t()
  def load(rows) when is_list(rows) do
    add(new(), Enum.map(rows, &from_row/1))
  end

  defp from_row(row) do
    Map.new(@stored_fields, fn key -> {key, Map.get(row, Atom.to_string(key))} end)
  end

  # --- ranking --------------------------------------------------------------

  defp rank(passages) do
    passages
    |> Enum.group_by(&identity/1)
    |> Enum.map(fn {_id, dupes} -> best_copy(dupes) end)
    |> drop_superseded()
    |> Enum.sort_by(& &1.similarity, :desc)
  end

  # Takes the text from the preferred copy but keeps the best similarity seen
  # for the identity at that revision. The translated copy is retrieved by a
  # later query and can score lower than the untranslated one it replaces;
  # inheriting that lower score would push a page the conversation is about to
  # the bottom of the ranking and out of the byte budget.
  defp best_copy(dupes) do
    best = Enum.max_by(dupes, &{revision(&1), translation_rank(&1), &1.similarity})

    similarity =
      dupes
      |> Enum.filter(&(revision(&1) == revision(best)))
      |> Enum.map(& &1.similarity)
      |> Enum.max()

    %{best | similarity: similarity}
  end

  defp fit(ranked) do
    {kept, _bytes, _count} =
      Enum.reduce(ranked, {[], 0, 0}, fn passage, {kept, bytes, count} = acc ->
        size = passage_bytes(passage)

        if count < @max_passages and bytes + size <= @max_bytes do
          {[passage | kept], bytes + size, count + 1}
        else
          acc
        end
      end)

    Enum.reverse(kept)
  end

  defp passage_bytes(passage) do
    byte_size(passage.original_markdown || "") +
      byte_size(passage.translated_markdown || "") +
      byte_size("[Page #{passage.page_number}]\n") + byte_size("\n\n---\n\n")
  end

  defp identity(passage), do: {passage.page_id, Map.get(passage, :chunk_index)}

  # Identity cannot fence a reprocessed page on its own: re-extraction deletes
  # and rebuilds chunks, so corrected text can arrive under a different chunk
  # index while the stale chunk keeps its own identity and rank.
  defp drop_superseded(passages) do
    latest =
      Enum.reduce(passages, %{}, fn passage, acc ->
        Map.update(acc, passage.page_id, revision(passage), &max(&1, revision(passage)))
      end)

    Enum.filter(passages, fn passage ->
      revision(passage) == Map.fetch!(latest, passage.page_id)
    end)
  end

  defp revision(passage), do: Map.get(passage, :content_revision) || -1

  # Only the nil/non-nil boundary is ranked, which is sufficient because a
  # completed translation is never rewritten at the same revision: every
  # re-translation entry point requires `translation_status` to be pending,
  # processing, or error, and resetting a page for reprocessing moves
  # `extraction_status` off "completed" and so bumps the revision. Chunk
  # ranking is left untouched: chunk retrieval carries a nil translation.
  defp translation_rank(passage) do
    if page_level?(passage) and not is_nil(Map.get(passage, :translated_markdown)),
      do: 1,
      else: 0
  end

  defp page_level?(passage), do: is_nil(Map.get(passage, :chunk_index))

  # --- freshness ------------------------------------------------------------

  defp current?(passage, revision, translation) do
    Map.get(passage, :content_revision) == revision and
      (not page_level?(passage) or Map.get(passage, :translated_markdown) == translation)
  end

  # --- rendering ------------------------------------------------------------

  defp page_section(page_number, items) do
    content =
      items
      |> Enum.sort_by(&(Map.get(&1, :chunk_index) || 0))
      |> Enum.map(fn item -> String.trim(content(item) || "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if content != "", do: "[Page #{page_number}]\n#{content}"
  end

  defp content(%{chunk_index: index} = item) when is_integer(index), do: item.original_markdown
  defp content(item), do: item.translated_markdown || item.original_markdown
end
