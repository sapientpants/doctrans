defmodule Doctrans.Chat.Conversations do
  @moduledoc """
  Durable per-document chat, rotated to the latest 100 messages on each write.

  Questions are saved before generation and answers only when finalized. Reloads
  restore completed history and bounded retrieval context; unfinished questions
  remain visible but are never sent as completed history to the model.

  The Retrieved context (`Doctrans.Chat.RetrievedContext`) is saved with each
  answer and checked against the Pages it was read from on both write and read,
  so a corrected Page cannot keep answering with its previous text. Processing
  asks here to forget the context of a Page or Document whose content it is
  discarding; nothing else writes the saved context.
  """
  import Ecto.Query
  alias Doctrans.Chat
  alias Doctrans.Chat.{Message, RetrievedContext, Session}
  alias Doctrans.Documents.Revision
  alias Doctrans.Repo

  @spec load(Ecto.UUID.t()) :: %{
          messages: [Message.t()],
          history: [Chat.message()],
          context: RetrievedContext.t(),
          interrupted?: boolean()
        }
  def load(document_id) do
    case Repo.get_by(Session, document_id: document_id) do
      nil ->
        %{messages: [], history: [], context: RetrievedContext.new(), interrupted?: false}

      session ->
        snapshot(session)
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
          RetrievedContext.t(),
          Doctrans.Documents.Document.t()
        ) :: {:ok, Message.t(), RetrievedContext.t()} | {:error, term()}
  def finish(question, role, content, context, document) do
    Revision.with_current(document, fn _current ->
      finish(question, role, content, context)
    end)
  end

  @doc """
  Records the answer to `question` and, for an assistant answer, the Retrieved
  context it leaves the conversation with.

  The context is checked against its Pages under the session lock, which is
  what fences it against a page reset, and that checked context is both saved
  and handed back, so a caller holding the conversation in memory keeps exactly
  what was saved. An answer to a question rotation has already removed is
  recorded nowhere; its context still comes back checked.
  """
  @spec finish(Message.t(), String.t(), String.t(), RetrievedContext.t()) ::
          {:ok, Message.t(), RetrievedContext.t()} | {:error, term()}
  def finish(question, role, content, context) do
    Repo.transaction(fn ->
      session =
        Repo.one!(from s in Session, where: s.id == ^question.chat_session_id, lock: "FOR UPDATE")

      kept = RetrievedContext.current(context)

      # A slow answer must not resurrect a question already removed by rotation.
      case Repo.get(Message, question.id) do
        nil -> {%Message{id: "expired-#{question.id}", role: role, content: content}, kept}
        saved -> {record_answer(session, saved, role, content, kept), kept}
      end
    end)
    |> case do
      {:ok, {message, kept}} -> {:ok, message, kept}
      {:error, _reason} = error -> error
    end
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
    Repo.update!(
      Ecto.Changeset.change(session, retrieved_context: RetrievedContext.dump(context))
    )
  end

  @doc """
  Forgets the saved context read from `page_ids`, for a Document whose Pages
  are being reset.

  Runs in the caller's transaction, under the document lock the caller holds,
  so an answer in flight either sees the context gone when it saves or is
  refused by the run fence. The session itself is locked for the write.
  """
  @spec forget_pages(Ecto.UUID.t(), [Ecto.UUID.t()]) :: :ok
  def forget_pages(document_id, page_ids) do
    from(s in Session, where: s.document_id == ^document_id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn session ->
      context = RetrievedContext.load(session.retrieved_context)
      kept = RetrievedContext.forget_pages(context, page_ids)

      if kept != context do
        Repo.update!(
          Ecto.Changeset.change(session, retrieved_context: RetrievedContext.dump(kept))
        )
      end
    end)
  end

  @doc """
  Forgets the whole saved context of a Document whose content is being
  replaced. Runs in the caller's transaction, like `forget_pages/2`.
  """
  @spec forget_document(Ecto.UUID.t()) :: :ok
  def forget_document(document_id) do
    _ =
      from(s in Session, where: s.document_id == ^document_id)
      |> Repo.update_all(set: [retrieved_context: []])

    :ok
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
      |> RetrievedContext.load()
      |> RetrievedContext.current()

    %{
      messages: messages,
      history: history,
      context: context,
      interrupted?: match?(%Message{role: "user", completed: false}, List.last(messages))
    }
  end

  # Keep the last `Chat.history_exchanges/0` complete exchanges in
  # answer-completion order. Message insertion order alone cannot pair turns
  # generated concurrently in two tabs.
  # Rotation and pre-linkage messages may leave answers without a known question;
  # keep those visible, but never guess their pairing in model history.
  defp completed_history(messages) do
    questions = completed_questions(messages)

    messages
    |> Enum.filter(&(&1.role == "assistant" and &1.completed))
    |> Enum.flat_map(&paired_exchange(&1, questions))
    |> Enum.take(-Chat.history_exchanges())
    |> List.flatten()
    |> Enum.map(&Map.take(&1, [:role, :content]))
  end

  defp completed_questions(messages) do
    messages
    |> Enum.filter(&(&1.role == "user" and &1.completed))
    |> Map.new(&{&1.id, &1})
  end

  defp paired_exchange(answer, questions) do
    case Map.fetch(questions, answer.question_id) do
      {:ok, question} -> [[question, answer]]
      :error -> []
    end
  end
end
