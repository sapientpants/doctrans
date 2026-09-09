defmodule Doctrans.Chat.Conversations do
  @moduledoc """
  Durable per-document chat, rotated to the latest 100 messages on each write.

  Questions are saved before generation and answers only when finalized. Reloads
  restore completed history and bounded retrieval context; unfinished questions
  remain visible but are never sent as completed history to the model.
  """
  import Ecto.Query
  alias Doctrans.Chat
  alias Doctrans.Chat.{Message, Session}
  alias Doctrans.Repo

  @context_fields ~w(page_id page_number chunk_index similarity original_markdown translated_markdown)a

  def load(document_id) do
    case Repo.get_by(Session, document_id: document_id) do
      nil -> %{messages: [], history: [], context: [], interrupted?: false}
      session -> snapshot(session)
    end
  end

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

  def finish(question, role, content, context) do
    Repo.transaction(fn ->
      session =
        Repo.one!(from s in Session, where: s.id == ^question.chat_session_id, lock: "FOR UPDATE")

      # A slow answer must not resurrect a question already removed by rotation.
      case Repo.get(Message, question.id) do
        nil ->
          %Message{id: "expired-#{question.id}", role: role, content: content}

        saved ->
          _ = Repo.update!(Ecto.Changeset.change(saved, completed: role == "assistant"))

          message =
            Repo.insert!(%Message{
              chat_session_id: session.id,
              role: role,
              content: content,
              completed: role == "assistant"
            })

          if role == "assistant" do
            bounded = Chat.merge_context([], context)

            _ =
              Repo.update!(
                Ecto.Changeset.change(session,
                  retrieved_context: Enum.map(bounded, &Map.take(&1, @context_fields))
                )
              )
          end

          rotate(session.id)
          message
      end
    end)
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

    history =
      messages
      |> Enum.filter(& &1.completed)
      |> Enum.take(-16)
      |> Enum.map(&Map.take(&1, [:role, :content]))

    context =
      Enum.map(session.retrieved_context, fn chunk ->
        Map.new(@context_fields, fn key -> {key, Map.get(chunk, Atom.to_string(key))} end)
      end)

    %{
      messages: messages,
      history: history,
      context: context,
      interrupted?: match?(%Message{role: "user", completed: false}, List.last(messages))
    }
  end
end
