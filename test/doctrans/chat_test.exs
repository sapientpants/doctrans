defmodule Doctrans.ChatTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Chat
  alias Doctrans.Documents
  alias Doctrans.Documents.Pages

  describe "send_message/4" do
    test "returns error for empty question" do
      document = %{id: Ecto.UUID.generate(), title: "Test Doc"}

      assert {:error, :empty_question} = Chat.send_message(document, "", [])
      assert {:error, :empty_question} = Chat.send_message(document, nil, [])
    end

    test "returns response even when no relevant pages found" do
      # Create a document without pages - simulates no relevant content found
      document = create_document(status: "completed")

      # The stub will still return a response (the LLM is called with empty context)
      assert {:ok, response} = Chat.send_message(document, "What is this about?", [])
      assert is_binary(response)
      # Response should indicate no information found or be a mock response
      assert String.length(response) > 0
    end
  end

  describe "build_context/1" do
    test "returns empty string for empty list" do
      assert Chat.build_context([]) == ""
    end

    test "builds context from pages with translated content" do
      pages = [
        %{page_number: 1, translated_markdown: "Page 1 content", original_markdown: "Original 1"},
        %{page_number: 2, translated_markdown: "Page 2 content", original_markdown: "Original 2"}
      ]

      context = Chat.build_context(pages)

      assert String.contains?(context, "[Page 1]")
      assert String.contains?(context, "Page 1 content")
      assert String.contains?(context, "[Page 2]")
      assert String.contains?(context, "Page 2 content")
      # Should use translated, not original
      refute String.contains?(context, "Original 1")
    end

    test "falls back to original markdown when translated is nil" do
      pages = [
        %{page_number: 1, translated_markdown: nil, original_markdown: "Original content"}
      ]

      context = Chat.build_context(pages)

      assert String.contains?(context, "[Page 1]")
      assert String.contains?(context, "Original content")
    end

    test "skips pages with empty content" do
      pages = [
        %{page_number: 1, translated_markdown: "Has content", original_markdown: nil},
        %{page_number: 2, translated_markdown: nil, original_markdown: nil},
        %{page_number: 3, translated_markdown: "", original_markdown: ""}
      ]

      context = Chat.build_context(pages)

      assert String.contains?(context, "[Page 1]")
      refute String.contains?(context, "[Page 2]")
      refute String.contains?(context, "[Page 3]")
    end
  end

  describe "merge_context/3" do
    defp chunk(page_id, chunk_index, similarity) do
      %{
        page_id: page_id,
        page_number: 1,
        chunk_index: chunk_index,
        similarity: similarity,
        translated_markdown: "content",
        original_markdown: nil
      }
    end

    test "dedups by chunk identity {page_id, chunk_index}" do
      prior = [chunk("p1", 0, 0.9)]
      new = [chunk("p1", 0, 0.8), chunk("p1", 1, 0.7)]

      merged = Chat.merge_context(prior, new)

      assert length(merged) == 2
      assert Enum.map(merged, & &1.chunk_index) |> Enum.sort() == [0, 1]
    end

    test "keeps the higher-similarity copy on collision" do
      prior = [chunk("p1", 0, 0.5)]
      new = [chunk("p1", 0, 0.95)]

      assert [%{similarity: 0.95}] = Chat.merge_context(prior, new)
    end

    test "treats nil chunk_index (page-level results) as an identity" do
      prior = [chunk("p1", nil, 0.9)]
      new = [chunk("p1", nil, 0.8)]

      assert length(Chat.merge_context(prior, new)) == 1
    end

    test "caps the merged context and keeps the highest-similarity chunks" do
      chunks = for i <- 1..20, do: chunk("p#{i}", 0, i / 100)

      merged = Chat.merge_context([], chunks, max_chunks: 5)

      assert length(merged) == 5
      # The five highest similarities (0.16..0.20) survive.
      assert Enum.map(merged, & &1.similarity) == [0.20, 0.19, 0.18, 0.17, 0.16]
    end
  end

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

      # Create page with embedding using direct Repo insert to bypass changeset
      embedding = create_test_embedding()

      Doctrans.Repo.insert!(%Doctrans.Documents.Page{
        id: Ecto.UUID.generate(),
        document_id: document.id,
        page_number: 1,
        image_path: "documents/#{document.id}/pages/page_1.png",
        extraction_status: "completed",
        translation_status: "completed",
        embedding_status: "completed",
        embedding: embedding
      })

      assert Chat.embeddings_ready?(document)
    end

    test "returns false for document with no pages" do
      document = create_document(status: "completed")

      refute Chat.embeddings_ready?(document)
    end
  end

  # Helper to create a deterministic test embedding vector (1024 dimensions)
  defp create_test_embedding do
    List.duplicate(0.1, 1024)
    |> Pgvector.new()
  end

  defp create_document(opts) do
    attrs =
      Enum.into(opts, %{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de"
      })

    {:ok, document} = Documents.create_document(attrs)
    document
  end

  defp create_page(document, opts) do
    attrs =
      Enum.into(opts, %{
        image_path: "documents/#{document.id}/pages/page_1.png",
        extraction_status: "pending",
        translation_status: "pending",
        embedding_status: "pending"
      })

    {:ok, page} = Pages.create_page(document, attrs)
    page
  end
end
