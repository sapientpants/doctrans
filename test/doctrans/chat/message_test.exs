defmodule Doctrans.Chat.MessageTest do
  use ExUnit.Case, async: true

  alias Doctrans.Chat.Message
  alias Doctrans.Validation

  defp message(attrs) do
    struct!(
      %Message{chat_session_id: Ecto.UUID.generate(), role: "user", content: "Hello"},
      attrs
    )
  end

  test "a question within the byte bound is valid" do
    bound = String.duplicate("é", div(Validation.max_chat_question_bytes(), 2))
    assert Message.changeset(message(content: bound)).valid?
  end

  # The row knows nothing of characters: the byte bound is what it holds a
  # question to, so a writer that skipped the panel's validation is bounded too.
  test "a question is held to the question bound, counted in bytes" do
    over = String.duplicate("é", div(Validation.max_chat_question_bytes(), 2) + 1)
    changeset = Message.changeset(message(content: over))
    refute changeset.valid?
    assert {"should be at most %{count} byte(s)", _} = changeset.errors[:content]
  end

  test "an answer or error may exceed the question bound but not the content ceiling" do
    long = String.duplicate("a", Validation.max_chat_question_bytes() + 1)
    assert Message.changeset(message(role: "assistant", content: long)).valid?
    assert Message.changeset(message(role: "error", content: long)).valid?

    over = String.duplicate("a", Message.max_content_bytes() + 1)
    refute Message.changeset(message(role: "assistant", content: over)).valid?
  end

  test "a message needs a session, a known role and content" do
    refute Message.changeset(message(chat_session_id: nil)).valid?
    refute Message.changeset(message(role: "system")).valid?
    refute Message.changeset(message(content: nil)).valid?
  end
end
