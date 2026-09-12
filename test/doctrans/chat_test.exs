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

    test "enforces the exact byte boundary including both source fields and formatting" do
      item = %{chunk("p1", 0, 0.9) | original_markdown: "日本語"}
      budget = byte_size("日本語content[Page 1]\n\n\n---\n\n")

      assert Chat.merge_context([], [item], max_bytes: budget) == [item]
      assert Chat.merge_context([], [item], max_bytes: budget - 1) == []
      assert Chat.merge_context([], [item], max_bytes: 0) == []
    end

    test "drops oversized chunks and keeps smaller chunks in similarity order" do
      oversized = %{chunk("p1", nil, 1.0) | original_markdown: String.duplicate("x", 32_001)}
      high = chunk("p2", 0, 0.9)
      low = chunk("p3", 0, 0.8)

      assert Chat.merge_context([low], [oversized, high]) == [high, low]
    end

    test "a newer page revision wins over a higher-ranked older copy" do
      prior = [chunk("p1", 0, 0.95, content_revision: 1, content: "Assets are 10")]
      new = [chunk("p1", 0, 0.40, content_revision: 2, content: "Assets are 100")]

      assert [%{translated_markdown: "Assets are 100", content_revision: 2}] =
               Chat.merge_context(prior, new)
    end

    test "prefers the translated page copy over an untranslated one of the same revision" do
      prior = [chunk("p1", nil, 0.95, content_revision: 1, content: nil)]
      new = [chunk("p1", nil, 0.40, content_revision: 1, content: "Assets are 100")]

      assert [%{translated_markdown: "Assets are 100"}] = Chat.merge_context(prior, new)
    end

    test "the translated copy keeps the best similarity of the copies it replaces" do
      prior = [chunk("p1", nil, 0.95, content_revision: 1, content: nil)]
      new = [chunk("p1", nil, 0.40, content_revision: 1, content: "Assets are 100")]

      assert [%{translated_markdown: "Assets are 100", similarity: 0.95}] =
               Chat.merge_context(prior, new)
    end

    # Inheriting the translated copy's own lower score would sort the page to the
    # bottom and drop it, leaving the conversation without the page it is about.
    test "preferring the translation does not cost the page its place in the budget" do
      prior = [
        chunk("p1", nil, 0.95, content_revision: 1, content: nil),
        chunk("p2", nil, 0.89, content_revision: 1, content: "Other"),
        chunk("p3", nil, 0.88, content_revision: 1, content: "Other"),
        chunk("p4", nil, 0.87, content_revision: 1, content: "Other")
      ]

      new = [chunk("p1", nil, 0.40, content_revision: 1, content: "Assets are 100")]

      merged = Chat.merge_context(prior, new, max_chunks: 3)

      assert Enum.map(merged, & &1.page_id) == ["p1", "p2", "p3"]
    end

    test "a stale copy's similarity is not inherited across a revision bump" do
      prior = [chunk("p1", nil, 0.95, content_revision: 1, content: "Assets are 10")]
      new = [chunk("p1", nil, 0.40, content_revision: 2, content: "Assets are 100")]

      assert [%{content_revision: 2, similarity: 0.40}] = Chat.merge_context(prior, new)
    end

    # Chunk retrieval carries no translation, so the translation preference must
    # stay inert there and leave similarity as the only tie-break.
    test "translation presence does not reorder chunk-level copies" do
      prior = [chunk("p1", 0, 0.95, content_revision: 1, content: nil)]
      new = [chunk("p1", 0, 0.40, content_revision: 1, content: "Assets are 100")]

      assert [%{translated_markdown: nil, similarity: 0.95}] = Chat.merge_context(prior, new)
    end

    test "a newer revision supersedes older chunks of the same page under other indexes" do
      prior = [chunk("p1", 0, 0.95, content_revision: 1, content: "Assets are 10")]

      new = [
        chunk("p1", 2, 0.40, content_revision: 2, content: "Assets are 100"),
        chunk("p2", 0, 0.90, content_revision: 7, content: "Other page")
      ]

      merged = Chat.merge_context(prior, new)

      assert Enum.map(merged, & &1.translated_markdown) == ["Other page", "Assets are 100"]
    end

    test "context predating revision tracking loses to any known revision of its page" do
      prior = [chunk("p1", 0, 0.99, content: "Legacy")]
      new = [chunk("p1", 1, 0.10, content_revision: 0, content: "Current")]

      assert [%{translated_markdown: "Current"}] = Chat.merge_context(prior, new)
    end

    test "repeated turns stay within the byte budget even below the chunk limit" do
      context =
        Enum.reduce(1..40, [], fn i, prior ->
          item = %{chunk("p#{i}", 0, i / 100) | translated_markdown: String.duplicate("é", 4000)}
          merged = Chat.merge_context(prior, [item])

          assert byte_size(Chat.build_context(merged)) <= 32_000
          assert Enum.reduce(merged, 0, &(byte_size(&1.translated_markdown) + &2)) <= 32_000
          merged
        end)

      assert Enum.map(context, & &1.page_id) == ["p40", "p39", "p38"]
    end
  end

  describe "current_context/1" do
    setup do
      document = create_document(status: "completed")

      page =
        create_page(document,
          page_number: 1,
          extraction_status: "completed",
          original_markdown: "Assets are 10"
        )

      %{document: document, page: page}
    end

    test "keeps chunks matching the page's current revision", %{page: page} do
      context = [chunk(page.id, 0, 0.9, content_revision: page.content_revision)]

      assert Chat.current_context(context) == context
    end

    test "drops chunks whose page has been reprocessed since retrieval", %{page: page} do
      context = [chunk(page.id, 0, 0.9, content_revision: page.content_revision)]

      {:ok, _reset} = Documents.reset_page_for_reprocessing(page)

      assert Chat.current_context(context) == []
    end

    test "drops page context retrieved before the page was translated", %{page: page} do
      context = [chunk(page.id, nil, 0.9, content_revision: page.content_revision, content: nil)]

      assert Chat.current_context(context) == context

      {:ok, translated} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Aktiva sind 10"
        })

      assert translated.content_revision == page.content_revision
      assert Chat.current_context(context) == []
    end

    test "keeps page context carrying the page's current translation", %{page: page} do
      {:ok, translated} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Aktiva sind 10"
        })

      context = [
        chunk(page.id, nil, 0.9,
          content_revision: translated.content_revision,
          content: "Aktiva sind 10"
        )
      ]

      assert Chat.current_context(context) == context
    end

    # Chunk retrieval never carries a translation, so translation freshness
    # cannot be read from a nil `translated_markdown` there.
    test "keeps chunk context of a page translated after retrieval", %{page: page} do
      context = [chunk(page.id, 0, 0.9, content_revision: page.content_revision, content: nil)]

      {:ok, _translated} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Aktiva sind 10"
        })

      assert Chat.current_context(context) == context
    end

    # The content check catches more than the extraction-to-translation window: a
    # translation rewritten at one revision also leaves saved context stale.
    test "drops page context holding a superseded translation", %{page: page} do
      {:ok, first} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Aktiva sind 10"
        })

      context = [
        chunk(page.id, nil, 0.9,
          content_revision: first.content_revision,
          content: "Aktiva sind 10"
        )
      ]

      assert Chat.current_context(context) == context

      {:ok, second} =
        Documents.update_page_translation(first, %{translated_markdown: "Assets are 10"})

      assert second.content_revision == first.content_revision
      assert Chat.current_context(context) == []
    end

    test "drops chunks from deleted pages and chunks without a revision", %{page: page} do
      assert Chat.current_context([chunk(page.id, 0, 0.9)]) == []

      assert Chat.current_context([chunk(Ecto.UUID.generate(), 0, 0.9, content_revision: 0)]) ==
               []

      assert Chat.current_context([chunk("not-a-uuid", 0, 0.9, content_revision: 0)]) == []
      assert Chat.current_context([]) == []
    end
  end

  describe "superseded_by?/2" do
    setup do
      document = create_document(status: "completed")

      page =
        create_page(document,
          page_number: 1,
          extraction_status: "completed",
          original_markdown: "Assets are 10"
        )

      %{page: page}
    end

    test "a chunk read from another page is never superseded", %{page: page} do
      other = chunk(Ecto.UUID.generate(), nil, 0.9, content_revision: page.content_revision + 5)

      refute Chat.superseded_by?(other, page)
    end

    test "page context is superseded once the translation lands", %{page: page} do
      untranslated =
        chunk(page.id, nil, 0.9, content_revision: page.content_revision, content: nil)

      refute Chat.superseded_by?(untranslated, page)

      {:ok, translated} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Aktiva sind 10"
        })

      assert Chat.superseded_by?(untranslated, translated)

      current =
        chunk(page.id, nil, 0.9,
          content_revision: translated.content_revision,
          content: "Aktiva sind 10"
        )

      refute Chat.superseded_by?(current, translated)
    end

    test "chunk context is superseded only by a revision change", %{page: page} do
      context = chunk(page.id, 0, 0.9, content_revision: page.content_revision, content: nil)

      {:ok, translated} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "Aktiva sind 10"
        })

      refute Chat.superseded_by?(context, translated)
      assert Chat.superseded_by?(context, %{translated | content_revision: 99})
    end

    defp chunk(page_id, chunk_index, similarity, opts \\ []) do
      %{
        page_id: page_id,
        page_number: 1,
        chunk_index: chunk_index,
        content_revision: Keyword.get(opts, :content_revision),
        similarity: similarity,
        translated_markdown: Keyword.get(opts, :content, "content"),
        original_markdown: nil
      }
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
