defmodule Doctrans.Search.ChunkerTest do
  use ExUnit.Case, async: true

  alias Doctrans.Search.Chunker

  describe "chunk/1" do
    test "returns empty list for nil" do
      assert Chunker.chunk(nil) == []
    end

    test "returns empty list for empty string" do
      assert Chunker.chunk("") == []
    end

    test "returns empty list for whitespace-only string" do
      assert Chunker.chunk("   \n\n  ") == []
    end

    test "returns single chunk for short text" do
      text = "This is a short paragraph with just a few words."
      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      assert hd(chunks).chunk_index == 0
      assert hd(chunks).content == text
      assert hd(chunks).word_count > 0
      assert hd(chunks).start_offset >= 0
    end

    test "splits text into multiple chunks at paragraph boundaries" do
      # Create text with multiple paragraphs totaling > 300 words
      paragraphs =
        for i <- 1..10 do
          "Paragraph #{i}. " <> String.duplicate("word ", 40)
        end

      text = Enum.join(paragraphs, "\n\n")
      chunks = Chunker.chunk(text)

      assert length(chunks) > 1

      # Verify chunk indexes are sequential
      indexes = Enum.map(chunks, & &1.chunk_index)
      assert indexes == Enum.to_list(0..(length(chunks) - 1))

      # Verify all chunks have content
      assert Enum.all?(chunks, &(&1.content != ""))
      assert Enum.all?(chunks, &(&1.word_count > 0))
    end

    test "content_for_embedding includes overlap from previous chunk" do
      # Create enough text to force multiple chunks
      para1 = String.duplicate("alpha ", 160) |> String.trim()
      para2 = String.duplicate("beta ", 160) |> String.trim()
      para3 = String.duplicate("gamma ", 160) |> String.trim()

      text = "#{para1}\n\n#{para2}\n\n#{para3}"
      chunks = Chunker.chunk(text)

      assert length(chunks) > 1

      # Raw content should NOT contain overlap
      second = Enum.at(chunks, 1)
      refute String.contains?(second.content, "alpha")

      # But content_for_embedding should include overlap from previous chunk
      embed_content = Chunker.content_for_embedding(chunks, 1)
      first = Enum.at(chunks, 0)

      overlap_suffix =
        first.content
        |> String.split()
        |> Enum.take(-10)
        |> Enum.join(" ")

      assert overlap_suffix != ""
      assert String.contains?(embed_content, overlap_suffix)
    end

    test "preserves start and end offsets" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      chunks = Chunker.chunk(text)

      # Single chunk for short text
      assert length(chunks) == 1
      chunk = hd(chunks)
      assert chunk.start_offset >= 0
      assert chunk.end_offset > chunk.start_offset
    end

    test "handles text with only one paragraph" do
      text =
        "Just one paragraph with several sentences. It has no double newlines. Everything is together."

      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      assert hd(chunks).content == text
    end

    test "handles markdown with headings and lists" do
      text = """
      # Heading One

      This is the first section with some content about topic A.

      ## Sub-heading

      - Item one in the list
      - Item two in the list
      - Item three in the list

      Another paragraph under the sub-heading with more details.
      """

      chunks = Chunker.chunk(text)

      assert chunks != []
      # Should preserve markdown structure within chunks
      first_content = hd(chunks).content
      assert String.contains?(first_content, "# Heading One")
    end
  end
end
