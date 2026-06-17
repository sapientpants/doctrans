defmodule Doctrans.Chat do
  @moduledoc """
  Chat functionality for document Q&A using RAG (Retrieval-Augmented Generation).

  Provides semantic search within a single document and chat completions
  via Ollama's /api/chat endpoint.
  """

  alias Doctrans.Chat.MultiSearch
  alias Doctrans.Chat.QueryExpander
  alias Doctrans.Processing.ProviderResolver
  alias Doctrans.Search

  require Logger

  @doc """
  Sends a chat message and returns the LLM response.

  This function orchestrates the RAG pipeline:
  1. Searches document pages for relevant context using semantic search
  2. Builds a context string from the top-k pages
  3. Creates a system prompt with the document context
  4. Calls Ollama chat endpoint with the conversation history
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
      context_limit = Keyword.get(opts, :context_limit, 5)
      min_similarity = Keyword.get(opts, :min_similarity)

      Logger.info(
        "Processing chat question for document #{document.id}: #{String.slice(trimmed_question, 0, 100)}"
      )

      # Expand the query: reformulate with chat context + generate alternative phrasings
      {standalone_question, queries} = QueryExpander.expand(trimmed_question, chat_history, opts)

      search_opts =
        [limit: context_limit]
        |> then(fn o ->
          if min_similarity, do: Keyword.put(o, :min_similarity, min_similarity), else: o
        end)

      # Search with all query variants and merge via RRF
      search_result =
        if length(queries) > 1 do
          MultiSearch.search_with_queries(document.id, queries, search_opts)
        else
          Search.search_in_document(document.id, standalone_question, search_opts)
        end

      case search_result do
        {:ok, pages} ->
          log_search_results(pages, document.id)

          context = build_context(pages)

          Logger.debug(
            "Chat context (#{String.length(context)} chars):\n#{String.slice(context, 0, 500)}..."
          )

          system_prompt = build_system_prompt(document.title, context)
          # Use the standalone question so the LLM sees a clear, contextual question
          messages = build_messages(system_prompt, chat_history, standalone_question)

          case provider_module().chat(messages, opts) do
            {:ok, response} ->
              {:ok, response}

            {:error, reason} = error ->
              Logger.error("Chat failed for document #{document.id}: #{inspect(reason)}")
              error
          end

        {:error, reason} = error ->
          Logger.error("Chat search failed for document #{document.id}: #{inspect(reason)}")
          error
      end
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
  def build_context([]), do: ""

  def build_context(results) do
    results
    |> Enum.group_by(& &1.page_number)
    |> Enum.sort_by(fn {page_num, _} -> page_num end)
    |> Enum.map(fn {page_number, items} ->
      content =
        items
        |> Enum.sort_by(&(Map.get(&1, :chunk_index) || 0))
        |> Enum.map(fn item ->
          String.trim(item.translated_markdown || item.original_markdown || "")
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      if content != "" do
        "[Page #{page_number}]\n#{content}"
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end

  @doc """
  Checks if a document has any chunks or pages with embeddings ready for chat.

  Prefers chunks (fine-grained), falls back to page-level embeddings.
  """
  def embeddings_ready?(document) do
    import Ecto.Query

    # Check for chunk-level embeddings first
    chunk_count =
      Doctrans.Documents.Chunk
      |> join(:inner, [c], p in assoc(c, :page))
      |> where([c, p], p.document_id == ^document.id)
      |> where([c], c.embedding_status == "completed")
      |> where([c], not is_nil(c.embedding))
      |> Doctrans.Repo.aggregate(:count)

    if chunk_count > 0 do
      true
    else
      # Fall back to page-level embeddings
      page_count =
        Doctrans.Documents.Page
        |> where([p], p.document_id == ^document.id)
        |> where([p], p.embedding_status == "completed")
        |> where([p], not is_nil(p.embedding))
        |> Doctrans.Repo.aggregate(:count)

      page_count > 0
    end
  end

  # Private functions

  defp provider_module, do: ProviderResolver.resolve()

  defp build_system_prompt(document_title, context) when context == "" do
    """
    You answer questions about the document "#{document_title}".

    No relevant content was found in the document for this question.

    Respond with a brief, factual statement that the requested information was not found in the document. Do not apologize, do not offer suggestions, do not speculate. Simply state the fact.

    Example response: "This information is not present in the document."
    """
  end

  defp build_system_prompt(document_title, context) do
    """
    You answer questions about the document "#{document_title}" based strictly on the provided context.

    RULES:
    - Answer ONLY using information explicitly stated in the context below
    - If the context does not contain the answer, state clearly: "This information is not in the document."
    - Do NOT speculate, infer, or provide information beyond what is in the context
    - Do NOT use phrases like "I think", "probably", "might be", "it seems"
    - Do NOT apologize or use filler phrases like "Great question!" or "I'd be happy to help"
    - Be direct, factual, and concise
    - Cite page numbers when referencing specific information (e.g., "Page 3 states...")
    - If only partial information is available, state what is known and what is not

    DOCUMENT CONTEXT:
    #{context}
    """
  end

  defp build_messages(system_prompt, chat_history, question) do
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
