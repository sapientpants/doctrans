defmodule Doctrans.Chat.ConversationsTest do
  use Doctrans.DataCase, async: true
  alias Doctrans.Chat.{Conversations, Message, Session}
  alias Doctrans.Documents

  setup do
    {:ok, document} =
      Documents.create_document(%{
        title: "Chat",
        original_filename: "chat.pdf",
        target_language: "de"
      })

    %{document: document}
  end

  test "restores completed history and context but excludes failed and unfinished questions", %{
    document: document
  } do
    context = [
      %{
        page_id: Ecto.UUID.generate(),
        page_number: 1,
        chunk_index: 0,
        similarity: 0.9,
        original_markdown: "Source",
        translated_markdown: nil
      }
    ]

    question = Conversations.start_question(document.id, "Question")
    assert Conversations.load(document.id).interrupted?
    assert {:ok, _} = Conversations.finish(question, "assistant", "Answer", context)
    failed = Conversations.start_question(document.id, "Failed question")
    assert {:ok, _} = Conversations.finish(failed, "error", "Failure", [])
    refute Conversations.load(document.id).interrupted?
    _ = Conversations.start_question(document.id, "Pending")
    saved = Conversations.load(document.id)
    assert saved.context == context

    assert saved.history == [
             %{role: "user", content: "Question"},
             %{role: "assistant", content: "Answer"}
           ]

    assert length(saved.messages) == 5
    assert saved.interrupted?
    assert Conversations.load(Ecto.UUID.generate()).messages == []
  end

  test "overlapping turns restore complete pairs in answer completion order", %{
    document: document
  } do
    first = Conversations.start_question(document.id, "Question A")
    second = Conversations.start_question(document.id, "Question B")
    assert {:ok, answer_b} = Conversations.finish(second, "assistant", "Answer B", [])
    assert {:ok, answer_a} = Conversations.finish(first, "assistant", "Answer A", [])
    assert answer_a.question_id == first.id
    assert answer_b.question_id == second.id

    assert Conversations.load(document.id).history == [
             %{role: "user", content: "Question B"},
             %{role: "assistant", content: "Answer B"},
             %{role: "user", content: "Question A"},
             %{role: "assistant", content: "Answer A"}
           ]
  end

  test "rotation excludes orphan answers from model history", %{document: document} do
    question = Conversations.start_question(document.id, "Old question")
    assert {:ok, answer} = Conversations.finish(question, "assistant", "Old answer", [])

    for n <- 1..99 do
      Conversations.start_question(document.id, "Pending #{n}")
    end

    saved = Conversations.load(document.id)
    assert length(saved.messages) == 100
    assert hd(saved.messages).id == answer.id
    assert hd(saved.messages).question_id == nil
    assert saved.history == []
  end

  test "legacy unlinked messages remain visible without guessed pairings", %{document: document} do
    question = Conversations.start_question(document.id, "Legacy question")
    Repo.update!(Ecto.Changeset.change(question, completed: true))

    Repo.insert!(%Message{
      chat_session_id: question.chat_session_id,
      role: "assistant",
      content: "Legacy answer",
      completed: true
    })

    saved = Conversations.load(document.id)
    assert length(saved.messages) == 2
    assert saved.history == []
  end

  test "rotates messages and cascades deletion", %{document: document} do
    for n <- 1..52 do
      question = Conversations.start_question(document.id, "Question #{n}")
      assert {:ok, _} = Conversations.finish(question, "assistant", "Answer #{n}", [])
    end

    saved = Conversations.load(document.id)
    assert length(saved.messages) == 100
    assert hd(saved.messages).content == "Question 3"
    assert length(saved.history) == 16
    assert Repo.aggregate(Session, :count) == 1
    Repo.delete!(document)
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end
end
