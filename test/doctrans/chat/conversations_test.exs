defmodule Doctrans.Chat.ConversationsTest do
  use Doctrans.DataCase, async: true
  alias Doctrans.Chat
  alias Doctrans.Chat.{Conversations, Message, RetrievedContext, Session}
  alias Doctrans.Documents
  alias Doctrans.Documents.PageLifecycle
  alias Doctrans.Fixtures

  setup do
    {:ok, document} =
      Documents.create_document(%{
        title: "Chat",
        original_filename: "chat.pdf",
        source_language: "en",
        target_language: "de"
      })

    %{document: document, page: Fixtures.completed_page_fixture(document)}
  end

  test "restores completed history and context but excludes failed and unfinished questions", %{
    document: document,
    page: page
  } do
    context =
      RetrievedContext.add(RetrievedContext.new(), [
        %{
          page_id: page.id,
          page_number: 1,
          chunk_index: 0,
          content_revision: page.content_revision,
          similarity: 0.9,
          original_markdown: "Source",
          translated_markdown: nil
        }
      ])

    question = Conversations.start_question(document.id, "Question")
    assert Conversations.load(document.id).interrupted?
    assert {:ok, _, ^context} = Conversations.finish(question, "assistant", "Answer", context)
    failed = Conversations.start_question(document.id, "Failed question")
    assert {:ok, _, _} = Conversations.finish(failed, "error", "Failure", RetrievedContext.new())
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

    assert {:ok, answer_b, _} =
             Conversations.finish(second, "assistant", "Answer B", RetrievedContext.new())

    assert {:ok, answer_a, _} =
             Conversations.finish(first, "assistant", "Answer A", RetrievedContext.new())

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

    assert {:ok, answer, _} =
             Conversations.finish(question, "assistant", "Old answer", RetrievedContext.new())

    for n <- 1..99 do
      Conversations.start_question(document.id, "Pending #{n}")
    end

    saved = Conversations.load(document.id)
    assert length(saved.messages) == 100
    assert hd(saved.messages).id == answer.id
    assert hd(saved.messages).question_id == nil
    assert saved.history == []
  end

  # The panel refuses an oversized question first; this is the row refusing it
  # too, so no other writer can store one.
  test "a question over the bound is refused at the row", %{document: document} do
    oversized = String.duplicate("a", Doctrans.Validation.max_chat_question_bytes() + 1)

    assert_raise Ecto.InvalidChangesetError, fn ->
      Conversations.start_question(document.id, oversized)
    end

    assert Conversations.load(document.id).messages == []
  end

  test "an answer over the content ceiling fails the write and leaves the question open", %{
    document: document
  } do
    question = Conversations.start_question(document.id, "Short question")
    oversized = String.duplicate("a", Message.max_content_bytes() + 1)

    assert {:error, %Ecto.Changeset{errors: [content: _]}} =
             Conversations.finish(question, "assistant", oversized, RetrievedContext.new())

    assert %{messages: [%Message{role: "user", completed: false}], interrupted?: true} =
             Conversations.load(document.id)

    # The error message that replaces the answer is short, and is saved.
    assert {:ok, %Message{role: "error"}, _} =
             Conversations.finish(question, "error", "Sorry", RetrievedContext.new())
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

      assert {:ok, _, _} =
               Conversations.finish(question, "assistant", "Answer #{n}", RetrievedContext.new())
    end

    saved = Conversations.load(document.id)
    assert length(saved.messages) == 100
    assert hd(saved.messages).content == "Question 3"
    assert length(saved.history) == Chat.history_limit()
    assert Repo.aggregate(Session, :count) == 1
    Repo.delete!(document)
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "finish hands back the context it saved, checked under the lock", %{
    document: document,
    page: page
  } do
    other = Fixtures.completed_page_fixture(document, %{page_number: 2})

    context =
      RetrievedContext.add(RetrievedContext.new(), [
        Fixtures.passage_fixture(page),
        Fixtures.passage_fixture(other)
      ])

    question = Conversations.start_question(document.id, "Question")

    {:ok, _reset} = PageLifecycle.reset(page)

    assert {:ok, _answer, saved} = Conversations.finish(question, "assistant", "Answer", context)
    assert Enum.map(RetrievedContext.passages(saved), & &1.page_id) == [other.id]
    assert Conversations.load(document.id).context == saved
  end

  test "finish hands back the checked context for an answer rotation already removed", %{
    document: document,
    page: page
  } do
    other = Fixtures.completed_page_fixture(document, %{page_number: 2})

    context =
      RetrievedContext.add(RetrievedContext.new(), [
        Fixtures.passage_fixture(page),
        Fixtures.passage_fixture(other)
      ])

    question = Conversations.start_question(document.id, "Expired question")
    for n <- 1..100, do: Conversations.start_question(document.id, "Pending #{n}")

    {:ok, _reset} = PageLifecycle.reset(page)

    assert {:ok, %Message{id: "expired-" <> _}, checked} =
             Conversations.finish(question, "assistant", "Answer", context)

    assert Enum.map(RetrievedContext.passages(checked), & &1.page_id) == [other.id]

    # Nothing is recorded for the expired answer: no message, no context.
    saved = Conversations.load(document.id)
    assert length(saved.messages) == 100
    assert saved.context == RetrievedContext.new()
  end

  describe "forgetting saved context" do
    setup %{document: document, page: page} do
      other = Fixtures.completed_page_fixture(document, %{page_number: 2})

      context =
        RetrievedContext.add(RetrievedContext.new(), [
          Fixtures.passage_fixture(page),
          Fixtures.passage_fixture(other)
        ])

      question = Conversations.start_question(document.id, "Question")
      assert {:ok, _, _} = Conversations.finish(question, "assistant", "Answer", context)
      %{other: other}
    end

    test "forget_page drops the saved passages of that page alone", %{
      document: document,
      page: page,
      other: other
    } do
      assert :ok = Conversations.forget_page(document.id, page.id)

      assert Enum.map(
               RetrievedContext.passages(Conversations.load(document.id).context),
               & &1.page_id
             ) == [other.id]
    end

    test "forget_document drops the whole saved context", %{document: document} do
      assert :ok = Conversations.forget_document(document.id)
      assert Conversations.load(document.id).context == RetrievedContext.new()
    end

    test "forget_page on a document without a conversation is a no-op", %{page: page} do
      assert :ok = Conversations.forget_page(Ecto.UUID.generate(), page.id)
    end

    test "forget_document on a document without a conversation is a no-op" do
      assert :ok = Conversations.forget_document(Ecto.UUID.generate())
    end
  end
end
