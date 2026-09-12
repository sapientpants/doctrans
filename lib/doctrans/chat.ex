defmodule Doctrans.Chat do
  @moduledoc """
  Chat functionality for document Q&A using RAG (Retrieval-Augmented Generation).

  Provides semantic search within a single document and chat completions
  falling back to the API's /api/chat endpoint.
  """

  alias Doctrans.Chat.MultiSearch
  alias Doctrans.Chat.QueryExpander
  alias Doctrans.Documents
  alias Doctrans.Search

  require Logger

  @typedoc "A chat turn as the model sees it: saved history entries and request messages."
  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Sends a chat message and returns the LLM response.

  This function orchestrates the RAG pipeline:
  1. Searches document pages for relevant context using semantic search
  2. Builds a context string from the top-k pages
  3. Creates a system prompt with the document context
  4. calls the API chat endpoint with the conversation history
  5. Returns the response

  ## Parameters

  - `document` - The document struct (must have :id and :title)
  - `question` - The user's question
  - `chat_history` - List of previous messages (optional, default: [])
  - `opts` - Options (optional)

  ## Options

  - `:context_limit` - Number of pages to use for context (default: 5)
  - `:min_similarity` - Minimum similarity threshold for search results (default: none)
  - `:model` - Override the default chat model

  ## Returns

  - `{:ok, response_text}` on success
  - `{:error, reason}` on failure
  """
  @spec send_message(Documents.Document.t(), String.t() | nil, [message()], keyword()) ::
          {:ok, String.t()} | {:error, Doctrans.Errors.reason()}
  def send_message(document, question, chat_history \\ [], opts \\ [])

  def send_message(_document, "", _chat_history, _opts) do
    {:error, :empty_question}
  end

  def send_message(_document, nil, _chat_history, _opts) do
    {:error, :empty_question}
  end

  def send_message(document, question, chat_history, opts) do
    trimmed_question = String.trim(question)

    if trimmed_question == "" do
      {:error, :empty_question}
    else
      answer_question(document, trimmed_question, chat_history, opts)
    end
  end

  defp answer_question(document, question, chat_history, opts) do
    Logger.info(
      "Processing chat question for document #{document.id}: #{String.slice(question, 0, 100)}"
    )

    # Expand the query: reformulate with chat context + generate alternative phrasings
    {standalone_question, queries} = QueryExpander.expand(question, chat_history, opts)

    # Search with all query variants and merge via RRF
    case retrieve(document.id, standalone_question, queries, search_opts(opts)) do
      {:ok, pages} ->
        log_search_results(pages, document.id)
        request_answer(document, pages, standalone_question, chat_history, opts)

      {:error, reason} = error ->
        Logger.error("Chat search failed for document #{document.id}: #{inspect(reason)}")
        error
    end
  end

  defp search_opts(opts) do
    base = [limit: Keyword.get(opts, :context_limit, 5)]

    case Keyword.get(opts, :min_similarity) do
      nil -> base
      min_similarity -> Keyword.put(base, :min_similarity, min_similarity)
    end
  end

  defp request_answer(document, pages, standalone_question, chat_history, opts) do
    context = build_context(pages)

    Logger.debug(
      "Chat context (#{String.length(context)} chars):\n#{String.slice(context, 0, 500)}..."
    )

    system_prompt = build_system_prompt(document.title, context)
    # Use the standalone question so the LLM sees a clear, contextual question
    messages = build_messages(system_prompt, chat_history, standalone_question)

    case openai_module().chat(messages, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Chat failed for document #{document.id}: #{inspect(reason)}")
        error
    end
  end

  defp log_search_results([], document_id) do
    Logger.info("No relevant pages found for chat in document #{document_id}")
  end

  defp log_search_results(pages, document_id) do
    page_info =
      Enum.map_join(pages, ", ", fn p ->
        "page #{p.page_number} (sim: #{Float.round(p.similarity, 3)})"
      end)

    Logger.info(
      "Found #{length(pages)} relevant pages for chat in document #{document_id}: #{page_info}"
    )
  end

  @doc """
  Builds a context string from a list of search results (chunks or pages).

  Groups results by page number and formats each page section with its
  page number for citation. When multiple chunks come from the same page,
  they are sorted by chunk_index and joined together.
  """
  @spec build_context([Search.document_result()]) :: String.t()
  def build_context([]), do: ""

  def build_context(results) do
    results
    |> Enum.group_by(& &1.page_number)
    |> Enum.sort_by(fn {page_number, _items} -> page_number end)
    |> Enum.map(fn {page_number, items} -> page_section(page_number, items) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp page_section(page_number, items) do
    content =
      items
      |> Enum.sort_by(&(Map.get(&1, :chunk_index) || 0))
      |> Enum.map(fn item -> String.trim(context_content(item) || "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if content != "", do: "[Page #{page_number}]\n#{content}"
  end

  # Old saved chunk context can still contain translations paired by index.
  # Only whole-page results have a reliable source/translation boundary.
  defp context_content(%{chunk_index: index} = item) when is_integer(index),
    do: item.original_markdown

  defp context_content(item), do: item.translated_markdown || item.original_markdown

  @max_context_chunks 16
  @max_context_bytes 32_000

  @doc """
  Merges newly retrieved chunks into the prior accumulated conversation context.

  Dedups by chunk identity `{page_id, chunk_index}` (chunk_index is nil for
  page-level results) and drops every chunk superseded by a newer
  `:content_revision` of the same page, so a reprocessed page cannot keep
  serving its previous text. Revision wins over similarity: a higher-ranked
  copy of an older revision is obsolete, not preferable. Chunks carrying no
  revision predate revision tracking and rank below any known revision.

  Within one revision, a page-level copy carrying the page's translation
  outranks a copy retrieved before that translation was written: writing a
  translation does not advance the revision, so similarity alone would keep
  serving the untranslated text. The surviving copy keeps the best similarity
  recorded for its identity at that revision, so preferring the translation
  never costs the page its rank.

  The surviving chunks are sorted by similarity descending and retained within
  both `:max_chunks` (default 16) and `:max_bytes` (default 32,000). The byte
  budget counts both markdown fields plus page labels and separators, bounding
  stored source text as well as rendered retrieval context. This is not a model
  token limit.

  Chunks that do not fit are dropped, allowing smaller, lower-ranked chunks to
  use the remaining budget. Budget drops are logged without document content.

  Returns the merged chunk list, suitable for `build_context/1`.
  """
  @spec merge_context([Search.document_result()], [Search.document_result()], keyword()) :: [
          Search.document_result()
        ]
  def merge_context(prior_chunks, new_chunks, opts \\ []) do
    max_chunks = Keyword.get(opts, :max_chunks, @max_context_chunks)
    max_bytes = Keyword.get(opts, :max_bytes, @max_context_bytes)

    ranked = rank_context(prior_chunks ++ new_chunks)
    kept = fit_context(ranked, max_chunks, max_bytes)

    if length(kept) < length(ranked) do
      Logger.info(
        "Chat context budget dropped #{length(ranked) - length(kept)} chunks " <>
          "(max_chunks=#{max_chunks}, max_bytes=#{max_bytes})"
      )
    end

    kept
  end

  defp rank_context(chunks) do
    chunks
    |> Enum.group_by(&chunk_identity/1)
    |> Enum.map(fn {_id, dupes} -> best_copy(dupes) end)
    |> drop_superseded()
    |> Enum.sort_by(& &1.similarity, :desc)
  end

  # Takes the text from the preferred copy but keeps the best similarity seen
  # for the identity at that revision. The translated copy is retrieved by a
  # later query and can score lower than the untranslated one it replaces;
  # inheriting that lower score would push a page the conversation is about to
  # the bottom of the ranking and out of the byte budget below.
  defp best_copy(dupes) do
    best = Enum.max_by(dupes, &{revision(&1), translation_rank(&1), &1.similarity})

    similarity =
      dupes
      |> Enum.filter(&(revision(&1) == revision(best)))
      |> Enum.map(& &1.similarity)
      |> Enum.max()

    %{best | similarity: similarity}
  end

  defp fit_context(ranked, max_chunks, max_bytes) do
    {kept, _bytes, _count} =
      Enum.reduce(ranked, {[], 0, 0}, fn chunk, {kept, bytes, count} = acc ->
        size = context_chunk_bytes(chunk)

        if count < max_chunks and bytes + size <= max_bytes do
          {[chunk | kept], bytes + size, count + 1}
        else
          acc
        end
      end)

    Enum.reverse(kept)
  end

  defp context_chunk_bytes(chunk) do
    byte_size(chunk.original_markdown || "") +
      byte_size(chunk.translated_markdown || "") +
      byte_size("[Page #{chunk.page_number}]\n") + byte_size("\n\n---\n\n")
  end

  defp chunk_identity(chunk), do: {chunk.page_id, Map.get(chunk, :chunk_index)}

  # Chunk identity cannot fence a reprocessed page on its own: re-extraction
  # deletes and rebuilds chunks, so corrected text can arrive under a different
  # chunk index while the stale chunk keeps its own identity and rank.
  defp drop_superseded(chunks) do
    latest =
      Enum.reduce(chunks, %{}, fn chunk, acc ->
        Map.update(acc, chunk.page_id, revision(chunk), &max(&1, revision(chunk)))
      end)

    Enum.filter(chunks, fn chunk -> revision(chunk) == Map.fetch!(latest, chunk.page_id) end)
  end

  defp revision(chunk), do: Map.get(chunk, :content_revision) || -1

  # Page embeddings are generated as soon as extraction completes, so the same
  # page can be retrieved twice at one revision: once before its translation is
  # written and once after. Chunk ranking is left untouched: chunk retrieval
  # carries a nil translation, and a translation on legacy saved chunk context
  # is ignored for freshness just as `context_content/1` ignores it for
  # rendering.
  #
  # Only the nil/non-nil boundary is ranked, which is sufficient because a
  # completed translation is never rewritten at the same revision: every
  # re-translation entry point requires `translation_status` to be pending,
  # processing, or error, and resetting a page for reprocessing moves
  # `extraction_status` off "completed" and so bumps the revision.
  defp translation_rank(chunk) do
    if page_level?(chunk) and not is_nil(Map.get(chunk, :translated_markdown)), do: 1, else: 0
  end

  defp page_level?(chunk), do: is_nil(Map.get(chunk, :chunk_index))

  @doc """
  Keeps only the chunks that still match their source page's current text.

  Retrieval context outlives the text it was built from: a single-page
  reprocess replaces a page's content while accumulated context, saved context,
  and in-flight answers still hold the previous text. Chunks whose page was
  deleted, reprocessed, or predates revision tracking cannot be shown to be
  current and are dropped.

  A matching revision is not sufficient for page-level context. `content_revision`
  advances on extraction, not on translation, and page embeddings are generated
  as soon as extraction completes, so a page answered between the two is stored
  untranslated at a revision that stays current once the translation lands. Such
  context is dropped as well; the next turn retrieves the translated page.
  """
  @spec current_context([Search.document_result()]) :: [Search.document_result()]
  def current_context([]), do: []

  def current_context(chunks) do
    pages =
      chunks
      |> Enum.map(&Map.get(&1, :page_id))
      |> Documents.page_content_state()

    kept =
      Enum.filter(chunks, fn chunk ->
        case Map.get(pages, Map.get(chunk, :page_id)) do
          nil -> false
          {revision, translation} -> current_chunk?(chunk, revision, translation)
        end
      end)

    if length(kept) < length(chunks) do
      Logger.info(
        "Chat context dropped #{length(chunks) - length(kept)} chunks from stale page content"
      )
    end

    kept
  end

  @doc """
  Checks one accumulated chunk against a page an update was broadcast for.

  A socket keeps its retrieval context between turns, so a page changed in
  another tab has to be evicted where it is held. Applies `current_context/1`'s
  test to callers that already hold the updated page.

  A chunk read from another page is never superseded by this one, so callers can
  pass their whole accumulated context without pre-filtering by `page_id`.
  """
  @spec superseded_by?(Search.document_result(), Documents.Page.t()) :: boolean()
  def superseded_by?(chunk, page) do
    Map.get(chunk, :page_id) == page.id and
      not current_chunk?(chunk, page.content_revision, page.translated_markdown)
  end

  defp current_chunk?(chunk, revision, translation) do
    Map.get(chunk, :content_revision) == revision and
      (not page_level?(chunk) or Map.get(chunk, :translated_markdown) == translation)
  end

  @doc """
  Checks if a document has any chunks or pages with embeddings ready for chat.

  Prefers chunks (fine-grained), falls back to page-level embeddings. Accepts a
  `Document` struct or a bare document id.
  """
  @spec embeddings_ready?(Documents.Document.t() | Ecto.UUID.t()) :: boolean()
  defdelegate embeddings_ready?(document), to: Documents

  # Private functions

  defp openai_module do
    Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)
  end

  @doc """
  Retrieves relevant document context for a set of search queries.

  Runs multi-query search with RRF when there are multiple query variants,
  otherwise a single semantic search using the supplied query, falling back to
  the standalone question only when no queries are supplied.
  Returns `{:ok, pages}` or `{:error, reason}`.
  Shared by `send_message/4` and `Doctrans.Chat.Agent`.
  """
  @spec retrieve(Ecto.UUID.t(), String.t(), [String.t()], keyword()) ::
          {:ok, [Search.document_result()]} | {:error, Doctrans.Errors.reason()}
  def retrieve(document_id, standalone_question, queries, search_opts) do
    case queries do
      [] -> Search.search_in_document(document_id, standalone_question, search_opts)
      [query] -> Search.search_in_document(document_id, query, search_opts)
      queries -> MultiSearch.search_with_queries(document_id, queries, search_opts)
    end
  end

  @doc false
  @spec build_system_prompt(String.t(), String.t()) :: String.t()
  def build_system_prompt(document_title, context) when context == "" do
    """
    You answer questions about the document "#{document_title}".

    The document was searched but no content relevant to this question was retrieved.

    State briefly that the specific information needed to answer was not found in the retrieved content. Do not apologize or speculate.
    """
  end

  @doc false
  def build_system_prompt(document_title, context) do
    """
    You are an analyst answering questions about the document "#{document_title}" using the DOCUMENT CONTEXT below as your source of facts.

    You may analyze, compare, evaluate, and draw conclusions from that information — including assessments, judgments, and opinions — when the question calls for it. An assessment is expected to reason over the available data, not to quote a ready-made conclusion.

    RULES:
    - Ground every fact and figure (numbers, dates, names) strictly in the context; never invent or assume figures that are not present
    - When asked to assess, evaluate, or give an opinion, reason over the relevant data in the context (e.g., balance-sheet figures, ratios, trends) and explain the basis for your conclusion
    - Cite page numbers and the specific figures you rely on (e.g., "equity of EUR 45m against total assets of EUR 120m (Page 12) implies an equity ratio of ~38%")
    - If a specific figure needed for part of the answer is not in the context, say exactly what is missing — do NOT refuse the whole question when related data is available
    - Be direct, concise, and analytical; avoid filler and hedging

    DOCUMENT CONTEXT:
    #{context}
    """
  end

  @doc false
  @spec build_messages(String.t(), [message()], String.t()) :: [message()]
  def build_messages(system_prompt, chat_history, question) do
    # Start with system prompt
    system_message = %{role: "system", content: system_prompt}

    # Add chat history (limit to last 8 messages to avoid context overflow)
    history_messages =
      chat_history
      |> Enum.take(-8)
      |> Enum.map(fn msg ->
        %{role: msg.role, content: msg.content}
      end)

    # Add the current question
    user_message = %{role: "user", content: question}

    [system_message | history_messages] ++ [user_message]
  end
end
