defmodule Doctrans.Search.RetrievalAlignmentTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.{Chat, Repo, Search}
  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Search.{Chunker, Indexer}
  alias Mix.Tasks.RechunkDocuments

  import Doctrans.Fixtures

  for {scenario, source_words, translated_words} <- [
        {:expansion, 140, 220},
        {:contraction, 220, 140}
      ],
      path <- [:indexer, :maintenance] do
    @source_words source_words
    @translated_words translated_words
    @path path

    test "#{scenario} preserves source passages through #{path} indexing and chat" do
      source = passages(@source_words, ["Vermögen", "Schulden", "Bargeld"])
      translation = passages(@translated_words, ["Assets", "Liabilities", "Cash"])
      source_chunks = Chunker.chunk(source)
      refute length(source_chunks) == length(Chunker.chunk(translation))

      document = document_fixture()

      page =
        page_fixture(document, %{
          extraction_status: "completed",
          original_markdown: source,
          translation_status: "completed",
          translated_markdown: translation
        })

      case @path do
        :indexer -> assert :ok = Indexer.index_page(page.id)
        :maintenance -> RechunkDocuments.run([])
      end

      chunks =
        Chunk
        |> where([c], c.page_id == ^page.id)
        |> order_by([c], c.chunk_index)
        |> Repo.all()

      assert Enum.map(chunks, & &1.content) == Enum.map(source_chunks, & &1.content)
      assert Enum.all?(chunks, &is_nil(&1.translated_content))
      assert Enum.all?(chunks, &(&1.embedding_status == "completed"))
      assert Enum.map_join(chunks, "\n\n", & &1.content) == source
      assert Repo.get!(Page, page.id).translated_markdown == translation

      # Legacy indexes must be safe immediately, without a model call or rebuild.
      Chunk
      |> where([c], c.page_id == ^page.id)
      |> Repo.update_all(set: [translated_content: "Unrelated legacy translation"])

      vector = hd(chunks).embedding
      assert {:ok, results} = Search.search_by_embedding(document.id, vector, limit: 20)

      assert MapSet.new(Enum.map(results, & &1.original_markdown)) ==
               MapSet.new(Enum.map(chunks, & &1.content))

      assert Enum.all?(results, &is_nil(&1.translated_markdown))

      assert Enum.all?(
               results,
               &(&1.content_revision == Repo.get!(Page, page.id).content_revision)
             )

      assert Chat.build_context(results) == "[Page 1]\n" <> source

      # Persisted conversation context predating this fix still has the bad pairing.
      legacy =
        Enum.map(results, &Map.put(&1, :translated_markdown, "Unrelated legacy translation"))

      assert Chat.build_context(Chat.merge_context([], legacy)) == "[Page 1]\n" <> source
    end
  end

  defp passages(words, labels) do
    Enum.map_join(labels, "\n\n", fn label ->
      Enum.join([label | List.duplicate("detail", words - 1)], " ")
    end)
  end
end
