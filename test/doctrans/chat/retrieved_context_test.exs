defmodule Doctrans.Chat.RetrievedContextTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Chat.RetrievedContext
  alias Doctrans.Documents
  alias Doctrans.Documents.PageLifecycle

  @max_passages 16
  @max_bytes 32_000

  describe "add/2" do
    test "an empty context has no passages and renders nothing" do
      assert RetrievedContext.passages(RetrievedContext.new()) == []
      assert RetrievedContext.prompt_text(RetrievedContext.new()) == ""
    end

    test "dedups by passage identity {page_id, chunk_index}" do
      merged =
        context([passage("p1", 0, 0.9)]) |> add([passage("p1", 0, 0.8), passage("p1", 1, 0.7)])

      assert length(passages(merged)) == 2
      assert Enum.map(passages(merged), & &1.chunk_index) |> Enum.sort() == [0, 1]
    end

    test "keeps the higher-similarity copy on collision" do
      merged = context([passage("p1", 0, 0.5)]) |> add([passage("p1", 0, 0.95)])

      assert [%{similarity: 0.95}] = passages(merged)
    end

    test "treats nil chunk_index (whole-page passages) as an identity" do
      merged = context([passage("p1", nil, 0.9)]) |> add([passage("p1", nil, 0.8)])

      assert length(passages(merged)) == 1
    end

    test "ranks by similarity and caps the context at #{@max_passages} passages" do
      merged = context(for i <- 1..20, do: passage("p#{i}", 0, i / 100))

      assert length(passages(merged)) == @max_passages
      # The sixteen highest similarities (0.05..0.20) survive, best first.
      assert Enum.map(passages(merged), & &1.similarity) == Enum.map(20..5//-1, &(&1 / 100))
    end

    test "enforces the exact byte boundary including both text fields and formatting" do
      formatting = byte_size("[Page 1]\n") + byte_size("\n\n---\n\n") + byte_size("content")

      exact = %{
        passage("p1", 0, 0.9)
        | original_markdown: String.duplicate("x", @max_bytes - formatting)
      }

      over = %{exact | original_markdown: exact.original_markdown <> "x"}

      assert passages(context([exact])) == [exact]
      assert passages(context([over])) == []
    end

    test "drops oversized passages and keeps smaller passages in similarity order" do
      oversized = %{passage("p1", nil, 1.0) | original_markdown: String.duplicate("x", 32_001)}
      high = passage("p2", 0, 0.9)
      low = passage("p3", 0, 0.8)

      assert passages(context([low]) |> add([oversized, high])) == [high, low]
    end

    test "a newer page revision wins over a higher-ranked older copy" do
      prior = context([passage("p1", 0, 0.95, content_revision: 1, content: "Assets are 10")])

      merged =
        add(prior, [passage("p1", 0, 0.40, content_revision: 2, content: "Assets are 100")])

      assert [%{translated_markdown: "Assets are 100", content_revision: 2}] = passages(merged)
    end

    test "prefers the translated page copy over an untranslated one of the same revision" do
      prior = context([passage("p1", nil, 0.95, content_revision: 1, content: nil)])

      merged =
        add(prior, [passage("p1", nil, 0.40, content_revision: 1, content: "Assets are 100")])

      assert [%{translated_markdown: "Assets are 100"}] = passages(merged)
    end

    test "the translated copy keeps the best similarity of the copies it replaces" do
      prior = context([passage("p1", nil, 0.95, content_revision: 1, content: nil)])

      merged =
        add(prior, [passage("p1", nil, 0.40, content_revision: 1, content: "Assets are 100")])

      assert [%{translated_markdown: "Assets are 100", similarity: 0.95}] = passages(merged)
    end

    # Inheriting the translated copy's own lower score would sort the page to the
    # bottom and drop it, leaving the conversation without the page it is about.
    test "preferring the translation does not cost the page its place in the budget" do
      others =
        for i <- 2..(@max_passages + 1),
            do: passage("p#{i}", nil, 0.9 - i / 1000, content_revision: 1, content: "Other")

      prior = context([passage("p1", nil, 0.95, content_revision: 1, content: nil) | others])

      merged =
        add(prior, [passage("p1", nil, 0.40, content_revision: 1, content: "Assets are 100")])

      kept = Enum.map(passages(merged), & &1.page_id)
      assert length(kept) == @max_passages
      assert hd(kept) == "p1"
      refute "p#{@max_passages + 1}" in kept
    end

    test "a stale copy's similarity is not inherited across a revision bump" do
      prior = context([passage("p1", nil, 0.95, content_revision: 1, content: "Assets are 10")])

      merged =
        add(prior, [passage("p1", nil, 0.40, content_revision: 2, content: "Assets are 100")])

      assert [%{content_revision: 2, similarity: 0.40}] = passages(merged)
    end

    # Chunk retrieval carries no translation, so the translation preference must
    # stay inert there and leave similarity as the only tie-break.
    test "translation presence does not reorder chunk-level copies" do
      prior = context([passage("p1", 0, 0.95, content_revision: 1, content: nil)])

      merged =
        add(prior, [passage("p1", 0, 0.40, content_revision: 1, content: "Assets are 100")])

      assert [%{translated_markdown: nil, similarity: 0.95}] = passages(merged)
    end

    test "a newer revision supersedes older chunks of the same page under other indexes" do
      prior = context([passage("p1", 0, 0.95, content_revision: 1, content: "Assets are 10")])

      merged =
        add(prior, [
          passage("p1", 2, 0.40, content_revision: 2, content: "Assets are 100"),
          passage("p2", 0, 0.90, content_revision: 7, content: "Other page")
        ])

      assert Enum.map(passages(merged), & &1.translated_markdown) == [
               "Other page",
               "Assets are 100"
             ]
    end

    test "passages predating revision tracking lose to any known revision of their page" do
      prior = context([passage("p1", 0, 0.99, content: "Legacy")])
      merged = add(prior, [passage("p1", 1, 0.10, content_revision: 0, content: "Current")])

      assert [%{translated_markdown: "Current"}] = passages(merged)
    end

    test "repeated turns stay within the byte budget even below the passage limit" do
      final =
        Enum.reduce(1..40, RetrievedContext.new(), fn i, prior ->
          item = %{
            passage("p#{i}", 0, i / 100)
            | translated_markdown: String.duplicate("é", 4000)
          }

          merged = add(prior, [item])

          assert byte_size(RetrievedContext.prompt_text(merged)) <= @max_bytes

          assert Enum.reduce(passages(merged), 0, &(byte_size(&1.translated_markdown) + &2)) <=
                   @max_bytes

          merged
        end)

      assert Enum.map(passages(final), & &1.page_id) == ["p40", "p39", "p38"]
    end
  end

  describe "prompt_text/1" do
    test "renders each page with its label, from the translation when there is one" do
      text =
        context([
          %{
            passage("p1", nil, 0.9)
            | page_number: 1,
              translated_markdown: "Page 1 content",
              original_markdown: "Original 1"
          },
          %{
            passage("p2", nil, 0.8)
            | page_number: 2,
              translated_markdown: "Page 2 content",
              original_markdown: "Original 2"
          }
        ])
        |> RetrievedContext.prompt_text()

      assert text =~ "[Page 1]"
      assert text =~ "Page 1 content"
      assert text =~ "[Page 2]"
      assert text =~ "Page 2 content"
      refute text =~ "Original 1"
    end

    test "falls back to the source text when a page has no translation" do
      text =
        context([
          %{
            passage("p1", nil, 0.9)
            | translated_markdown: nil,
              original_markdown: "Original content"
          }
        ])
        |> RetrievedContext.prompt_text()

      assert text == "[Page 1]\nOriginal content"
    end

    test "renders chunks from their source text in chunk order, under one page label" do
      text =
        context([
          %{
            passage("p1", 1, 0.9)
            | original_markdown: "second",
              translated_markdown: "paired wrongly"
          },
          %{passage("p1", 0, 0.8) | original_markdown: "first", translated_markdown: nil}
        ])
        |> RetrievedContext.prompt_text()

      assert text == "[Page 1]\nfirst\n\nsecond"
    end

    test "skips pages with empty content" do
      text =
        context([
          %{
            passage("p1", nil, 0.9)
            | page_number: 1,
              translated_markdown: "Has content",
              original_markdown: nil
          },
          %{
            passage("p2", nil, 0.8)
            | page_number: 2,
              translated_markdown: nil,
              original_markdown: nil
          },
          %{
            passage("p3", nil, 0.7)
            | page_number: 3,
              translated_markdown: "",
              original_markdown: ""
          }
        ])
        |> RetrievedContext.prompt_text()

      assert text =~ "[Page 1]"
      refute text =~ "[Page 2]"
      refute text =~ "[Page 3]"
    end
  end

  describe "current/1" do
    setup do
      document = create_document(status: "completed")
      page = create_page(document, page_number: 1, original_markdown: "Assets are 10")
      %{document: document, page: page}
    end

    test "keeps passages matching the page's current revision", %{page: page} do
      ctx = context([passage(page.id, 0, 0.9, content_revision: page.content_revision)])

      assert RetrievedContext.current(ctx) == ctx
    end

    test "drops passages whose page has been reprocessed since retrieval", %{page: page} do
      ctx = context([passage(page.id, 0, 0.9, content_revision: page.content_revision)])

      {:ok, _reset} = PageLifecycle.reset(page)

      assert RetrievedContext.current(ctx) == RetrievedContext.new()
    end

    test "drops a page passage retrieved before the page was translated", %{page: page} do
      ctx =
        context([
          passage(page.id, nil, 0.9, content_revision: page.content_revision, content: nil)
        ])

      assert RetrievedContext.current(ctx) == ctx

      {:ok, translated} =
        PageLifecycle.complete(page, :translation, %{markdown: "Aktiva sind 10"})

      assert translated.content_revision == page.content_revision
      assert RetrievedContext.current(ctx) == RetrievedContext.new()
    end

    test "keeps a page passage carrying the page's current translation", %{page: page} do
      {:ok, translated} =
        PageLifecycle.complete(page, :translation, %{markdown: "Aktiva sind 10"})

      ctx =
        context([
          passage(page.id, nil, 0.9,
            content_revision: translated.content_revision,
            content: "Aktiva sind 10"
          )
        ])

      assert RetrievedContext.current(ctx) == ctx
    end

    # Chunk retrieval never carries a translation, so translation freshness
    # cannot be read from a nil `translated_markdown` there.
    test "keeps a chunk passage of a page translated after retrieval", %{page: page} do
      ctx =
        context([passage(page.id, 0, 0.9, content_revision: page.content_revision, content: nil)])

      {:ok, _translated} =
        PageLifecycle.complete(page, :translation, %{markdown: "Aktiva sind 10"})

      assert RetrievedContext.current(ctx) == ctx
    end

    # The content check catches more than the extraction-to-translation window: a
    # translation rewritten at one revision also leaves saved context stale.
    test "drops a page passage holding a superseded translation", %{page: page} do
      {:ok, first} =
        PageLifecycle.complete(page, :translation, %{markdown: "Aktiva sind 10"})

      ctx =
        context([
          passage(page.id, nil, 0.9,
            content_revision: first.content_revision,
            content: "Aktiva sind 10"
          )
        ])

      assert RetrievedContext.current(ctx) == ctx

      {:ok, second} =
        PageLifecycle.complete(first, :translation, %{markdown: "Assets are 10"})

      assert second.content_revision == first.content_revision
      assert RetrievedContext.current(ctx) == RetrievedContext.new()
    end

    test "drops a passage that predates revision tracking", %{page: page} do
      assert RetrievedContext.current(context([passage(page.id, 0, 0.9)])) ==
               RetrievedContext.new()
    end

    test "drops a passage whose page no longer exists" do
      ctx = context([passage(Ecto.UUID.generate(), 0, 0.9, content_revision: 0)])

      assert RetrievedContext.current(ctx) == RetrievedContext.new()
    end

    test "drops a passage whose page id is not an id at all" do
      ctx = context([passage("not-a-uuid", 0, 0.9, content_revision: 0)])

      assert RetrievedContext.current(ctx) == RetrievedContext.new()
    end

    test "leaves an empty context alone without reading any page" do
      assert RetrievedContext.current(RetrievedContext.new()) == RetrievedContext.new()
    end
  end

  describe "current_against/2" do
    setup do
      document = create_document(status: "completed")
      page = create_page(document, page_number: 1, original_markdown: "Assets are 10")
      %{page: page}
    end

    test "a passage read from another page is never superseded", %{page: page} do
      ctx =
        context([
          passage(Ecto.UUID.generate(), nil, 0.9, content_revision: page.content_revision + 5)
        ])

      assert RetrievedContext.current_against(ctx, page) == ctx
    end

    test "a page passage is superseded once the translation lands", %{page: page} do
      untranslated =
        context([
          passage(page.id, nil, 0.9, content_revision: page.content_revision, content: nil)
        ])

      assert RetrievedContext.current_against(untranslated, page) == untranslated

      {:ok, translated} =
        PageLifecycle.complete(page, :translation, %{markdown: "Aktiva sind 10"})

      assert RetrievedContext.current_against(untranslated, translated) == RetrievedContext.new()

      current =
        context([
          passage(page.id, nil, 0.9,
            content_revision: translated.content_revision,
            content: "Aktiva sind 10"
          )
        ])

      assert RetrievedContext.current_against(current, translated) == current
    end

    test "a chunk passage is superseded only by a revision change", %{page: page} do
      ctx =
        context([passage(page.id, 0, 0.9, content_revision: page.content_revision, content: nil)])

      {:ok, translated} =
        PageLifecycle.complete(page, :translation, %{markdown: "Aktiva sind 10"})

      assert RetrievedContext.current_against(ctx, translated) == ctx

      assert RetrievedContext.current_against(ctx, %{translated | content_revision: 99}) ==
               RetrievedContext.new()
    end
  end

  describe "forget_page/2" do
    test "drops every passage of the named page, whatever its state" do
      ctx = context([passage("p1", 0, 0.9), passage("p1", nil, 0.8), passage("p2", 0, 0.7)])

      forgotten = RetrievedContext.forget_page(ctx, "p1")
      assert Enum.map(passages(forgotten), & &1.page_id) == ["p2"]

      assert RetrievedContext.forget_page(ctx, "p3") == ctx
    end
  end

  describe "dump/1 and load/1" do
    test "a context survives the round trip through its stored form" do
      ctx =
        context([
          passage("p1", 0, 0.9, content_revision: 3),
          passage("p2", nil, 0.8, content_revision: 1)
        ])

      rows = RetrievedContext.dump(ctx)
      assert Enum.all?(rows, &(Map.keys(&1) |> Enum.all?(fn key -> is_atom(key) end)))

      stored =
        Enum.map(rows, fn row ->
          Map.new(row, fn {key, value} -> {Atom.to_string(key), value} end)
        end)

      assert RetrievedContext.load(stored) == ctx
    end

    test "the stored form carries only what a passage is restored from" do
      ctx = context([Map.put(passage("p1", 0, 0.9), :rrf_score, 0.5)])

      assert [row] = RetrievedContext.dump(ctx)
      refute Map.has_key?(row, :rrf_score)

      assert Map.keys(row) |> Enum.sort() ==
               ~w(chunk_index content_revision original_markdown page_id page_number similarity translated_markdown)a
    end

    test "loaded rows come back deduped, ranked and within budget" do
      rows =
        for i <- 1..20 do
          %{
            "page_id" => "p#{i}",
            "page_number" => i,
            "chunk_index" => 0,
            "content_revision" => 1,
            "similarity" => i / 100,
            "original_markdown" => "x",
            "translated_markdown" => nil
          }
        end

      loaded = RetrievedContext.load(rows ++ rows)

      assert length(passages(loaded)) == @max_passages
      assert hd(passages(loaded)).page_id == "p20"
    end
  end

  defp context(items), do: add(RetrievedContext.new(), items)
  defp add(ctx, items), do: RetrievedContext.add(ctx, items)
  defp passages(ctx), do: RetrievedContext.passages(ctx)

  defp passage(page_id, chunk_index, similarity, opts \\ []) do
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

  # A page whose extraction has completed through the lifecycle, so the row
  # carries the content revision production would give it.
  defp create_page(document, opts) do
    {markdown, opts} = Keyword.pop(opts, :original_markdown)

    attrs =
      Enum.into(opts, %{
        image_path: "documents/#{document.id}/pages/page_1.png",
        embedding_status: "pending"
      })

    {:ok, page} = Documents.create_page(document, attrs)
    {:ok, page} = PageLifecycle.complete(page, :extraction, %{markdown: markdown})
    page
  end
end
