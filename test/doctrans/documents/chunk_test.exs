defmodule Doctrans.Documents.ChunkTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.Chunk

  describe "changeset/2" do
    test "accepts the fields the indexer writes" do
      changeset =
        Chunk.changeset(%Chunk{}, %{
          chunk_index: 0,
          content: "A chunk of the page",
          start_offset: 0,
          end_offset: 19,
          word_count: 5
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :content) == "A chunk of the page"
    end

    test "does not cast the legacy translated_content column" do
      changeset =
        Chunk.changeset(%Chunk{}, %{
          chunk_index: 0,
          content: "A chunk of the page",
          translated_content: "Ein Abschnitt der Seite"
        })

      assert changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :translated_content)
    end
  end
end
