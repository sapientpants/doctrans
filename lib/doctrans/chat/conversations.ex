defmodule Doctrans.Chat.Conversations do
  @moduledoc """
  Durable per-document chat, rotated to the latest 100 messages on each write.

  Questions are saved before generation and answers only when finalized. Reloads
  restore completed history and bounded retrieval context; unfinished questions
  remain visible but are never sent as completed history to the model.

  Retrieval context is stored with the page revision each chunk was read from,
  and chunks whose page has since been reprocessed are dropped on both write and
  read, so a corrected page cannot keep answering with its previous text. Page
  context read between extraction and translation is dropped the same way once
  the translation lands, since translating does not advance the revision.
  """
  import Ecto.Query
  alias Doctrans.Chat
  alias Doctrans.Chat.{Message, Session}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @context_fields ~w(page_id page_number chunk_index content_revision similarity original_markdown translated_markdown)a

  @spec load(Ecto.UUID.t()) :: %{
          messages: [Message.t()],
          history: [Chat.message()],
          context: [Doctrans.Search.document_result()],
          interrupted?: boolean()
        }
  def load(document_id) do
    case Repo.get_by(Session, document_id: document_id) do
      nil -> %{messages: [], history: [], context: [], interrupted?: false}
      session -> snapshot(session)
    end
  end

  @spec start_question(Ecto.UUID.t(), String.t()) :: Message.t()
  def start_question(document_id, content) do
    {:ok, message} =
      Repo.transaction(fn ->
        _ =
          Repo.insert!(%Session{document_id: document_id},
            on_conflict: :nothing,
            conflict_target: :document_id
          )

        session = lock_session(document_id)

        message =
          Repo.insert!(%Message{chat_session_id: session.id, role: "user", content: content})

        rotate(session.id)
        message
      end)

    message
  end

  @doc """
  Saves a result only while its source processing run is still current.

  Lock the document before the session, matching document reprocessing, so a
  restart either clears this result's context afterwards or rejects the result.
  Single-page reprocessing takes the same document lock, so context outdated by
  a page reset is already visible here and is discarded rather than saved.
  """
  @spec finish(
          Message.t(),
          String.t(),
          String.t(),
          [Doctrans.Search.document_result()],
          Doctrans.Documents.Document.t()
        ) :: {:ok, Message.t()} | {:error, term()}
  def finish(question, role, content, context, document) do
    Run.with_current(document, fn _current ->
      finish(question, role, content, context)
    end)
  end

  @spec finish(Message.t(), String.t(), String.t(), [Doctrans.Search.document_result()]) ::
          {:ok, Message.t()} | {:error, term()}
  def finish(question, role, content, context) do
    Repo.transaction(fn ->
      session =
        Repo.one!(from s in Session, where: s.id == ^question.chat_session_id, lock: "FOR UPDATE")

      # A slow answer must not resurrect a question already removed by rotation.
      case Repo.get(Message, question.id) do
        nil -> %Message{id: "expired-#{question.id}", role: role, content: content}
        saved -> record_answer(session, saved, role, content, context)
      end
    end)
  end

  defp record_answer(session, question, role, content, context) do
    _ = Repo.update!(Ecto.Changeset.change(question, completed: role == "assistant"))

    message =
      Repo.insert!(%Message{
        chat_session_id: session.id,
        question_id: question.id,
        role: role,
        content: content,
        completed: role == "assistant"
      })

    if role == "assistant", do: save_context(session, context)

    rotate(session.id)
    message
  end

  defp save_context(session, context) do
    bounded = Chat.merge_context([], Chat.current_context(context))

    Repo.update!(
      Ecto.Changeset.change(session,
        retrieved_context: Enum.map(bounded, &Map.take(&1, @context_fields))
      )
    )
  end

  defp lock_session(document_id) do
    from(s in Session, where: s.document_id == ^document_id, lock: "FOR UPDATE")
    |> Repo.one!()
  end

  defp rotate(session_id) do
    retained =
      from m in Message,
        where: m.chat_session_id == ^session_id,
        order_by: [desc: m.id],
        limit: 100,
        select: m.id

    _ =
      from(m in Message,
        where: m.chat_session_id == ^session_id and m.id not in subquery(retained)
      )
      |> Repo.delete_all()

    :ok
  end

  defp snapshot(session) do
    messages =
      from(m in Message, where: m.chat_session_id == ^session.id, order_by: m.id)
      |> Repo.all()

    history = completed_history(messages)

    context =
      session.retrieved_context
      |> Enum.map(fn chunk ->
        Map.new(@context_fields, fn key -> {key, Map.get(chunk, Atom.to_string(key))} end)
      end)
      |> Chat.current_context()

    %{
      messages: messages,
      history: history,
      context: context,
      interrupted?: match?(%Message{role: "user", completed: false}, List.last(messages))
    }
  end

  # Keep the last eight complete exchanges in answer-completion order. Message
  # insertion order alone cannot pair turns generated concurrently in two tabs.
  # Rotation and pre-linkage messages may leave answers without a known question;
  # keep those visible, but never guess their pairing in model history.
  defp completed_history(messages) do
    questions =
      messages
      |> Enum.filter(&(&1.role == "user" and &1.completed))
      |> Map.new(&{&1.id, &1})

    messages
    |> Enum.filter(&(&1.role == "assistant" and &1.completed))
    |> Enum.flat_map(&paired_exchange(&1, questions))
    |> Enum.take(-8)
    |> List.flatten()
    |> Enum.map(&Map.take(&1, [:role, :content]))
  end

  defp paired_exchange(answer, questions) do
    case Map.fetch(questions, answer.question_id) do
      {:ok, question} -> [[question, answer]]
      :error -> []
    end
  end
end
