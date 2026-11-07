defmodule Doctrans.ChatTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Chat
  alias Doctrans.Documents
  alias Doctrans.Documents.PageLifecycle

  import Doctrans.Fixtures, only: [indexed_page_fixture: 1]

  describe "build_system_prompt/2" do
    test "with context, allows analysis and does not hard-refuse" do
      prompt = Chat.build_system_prompt("Report", "[Page 1] equity EUR 45m")

      assert prompt =~ "analyze"
      assert prompt =~ "[Page 1] equity EUR 45m"
      refute prompt =~ "This information is not in the document."
    end

    test "with empty context, states the info was not found without a canned refusal" do
      prompt = Chat.build_system_prompt("Report", "")

      assert prompt =~ "not found"
    end
  end

  describe "build_messages/3" do
    test "sends the model the shared history window, newest last" do
      history =
        for n <- 1..(Chat.history_limit() + 2),
            role = if(rem(n, 2) == 1, do: "user", else: "assistant") do
          %{role: role, content: "message #{n}"}
        end

      [system | rest] = Chat.build_messages("system", history, "question")

      assert system == %{role: "system", content: "system"}
      assert List.last(rest) == %{role: "user", content: "question"}

      sent = Enum.drop(rest, -1)
      assert length(sent) == Chat.history_limit()
      assert hd(sent).content == "message 3"
      assert List.last(sent).content == "message #{Chat.history_limit() + 2}"
    end
  end

  describe "embeddings_ready?/1" do
    test "returns false when no pages have embeddings" do
      document = create_document(status: "processing")

      create_page(document,
        page_number: 1,
        embedding_status: "pending",
        embedding: nil
      )

      refute Chat.embeddings_ready?(document)
    end

    test "returns true when at least one page has completed embeddings" do
      document = create_document(status: "completed")
      indexed_page_fixture(document)

      assert Chat.embeddings_ready?(document)
    end

    test "returns false for document with no pages" do
      document = create_document(status: "completed")

      refute Chat.embeddings_ready?(document)
    end
  end

  defp create_document(opts) do
    attrs =
      Enum.into(opts, %{
        title: "Test Document",
        original_filename: "test.pdf",
        source_language: "en",
        target_language: "de"
      })

    {:ok, document} = Documents.create_document(attrs)
    document
  end

  # A page whose extraction, when `:original_markdown` is given, has completed
  # through the lifecycle, so the row carries the content revision production
  # would give it.
  defp create_page(document, opts) do
    {markdown, opts} = Keyword.pop(opts, :original_markdown)

    attrs =
      Enum.into(opts, %{
        image_path: "documents/#{document.id}/pages/page_1.png",
        embedding_status: "pending"
      })

    {:ok, page} = Documents.create_page(document, attrs)

    if markdown do
      {:ok, page} = PageLifecycle.complete(page, :extraction, %{markdown: markdown})
      page
    else
      page
    end
  end
end
