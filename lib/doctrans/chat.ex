defmodule Doctrans.Chat do
  @moduledoc """
  Chat functionality for document Q&A using RAG (Retrieval-Augmented Generation).

  Holds the pieces `Doctrans.Chat.Agent` assembles into a turn around the
  Retrieved context (`Doctrans.Chat.RetrievedContext`): the history window every
  holder of history applies, and the prompt built from the context's rendering.
  """

  alias Doctrans.Documents
  alias Doctrans.Documents.Pages

  @typedoc "A chat turn as the model sees it: saved history entries and request messages."
  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(atom()) => term()
        }

  @history_exchanges 8

  @doc """
  The number of completed exchanges (a question and its answer) kept as chat
  history.

  This is the one window every holder of history applies: the saved history
  `Doctrans.Chat.Conversations` restores, the running history a chat session
  keeps between turns, and the history `build_messages/3` sends to the model.
  """
  @spec history_exchanges() :: pos_integer()
  def history_exchanges, do: @history_exchanges

  @doc """
  `history_exchanges/0` counted in messages: two per exchange.
  """
  @spec history_limit() :: pos_integer()
  def history_limit, do: 2 * @history_exchanges

  @doc """
  Checks if a document has any chunks or pages with embeddings ready for chat.

  Prefers chunks (fine-grained), falls back to page-level embeddings. Accepts a
  `Document` struct or a bare document id. Chat is the only consumer of this
  predicate, so it is reached here rather than through `Doctrans.Documents`.
  """
  @spec embeddings_ready?(Documents.Document.t() | Ecto.UUID.t()) :: boolean()
  defdelegate embeddings_ready?(document), to: Pages

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
    system_message = %{role: "system", content: system_prompt}

    # Callers already hold a bounded history; the window is applied again here
    # so the prompt never exceeds it whatever the caller passes.
    history_messages =
      chat_history
      |> Enum.take(-history_limit())
      |> Enum.map(fn msg -> %{role: msg.role, content: msg.content} end)

    user_message = %{role: "user", content: question}

    [system_message | history_messages] ++ [user_message]
  end
end
