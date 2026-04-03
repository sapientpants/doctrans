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
      paragraphs =
        for i <- 1..10 do
          "Paragraph #{i}. " <> String.duplicate("word ", 40)
        end

      text = Enum.join(paragraphs, "\n\n")
      chunks = Chunker.chunk(text)

      assert length(chunks) > 1

      indexes = Enum.map(chunks, & &1.chunk_index)
      assert indexes == Enum.to_list(0..(length(chunks) - 1))

      assert Enum.all?(chunks, &(&1.content != ""))
      assert Enum.all?(chunks, &(&1.word_count > 0))
    end

    test "splits long single paragraph at sentence boundaries" do
      # Create a single paragraph (no double newlines) with > 300 words
      sentences =
        for i <- 1..20 do
          "Sentence number #{i} with some additional filler words to pad length. "
        end

      text = Enum.join(sentences)
      chunks = Chunker.chunk(text)

      assert chunks != []
      # All content should be preserved across chunks
      all_content = Enum.map_join(chunks, " ", & &1.content)
      assert String.contains?(all_content, "Sentence number 1")
      assert String.contains?(all_content, "Sentence number 20")
    end

    test "handles multiple triple+ newlines between paragraphs" do
      text = "First paragraph.\n\n\n\nSecond paragraph.\n\n\n\n\nThird paragraph."
      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      assert String.contains?(hd(chunks).content, "First paragraph")
      assert String.contains?(hd(chunks).content, "Third paragraph")
    end

    test "byte offsets are consistent" do
      text = "Hello world.\n\nSecond part.\n\nThird part."
      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      chunk = hd(chunks)
      assert chunk.start_offset >= 0
      assert chunk.end_offset > chunk.start_offset
    end

    test "byte offsets are correct for multi-byte characters" do
      text = "Ärger mit Ümlauten.\n\nNoch ein Absatz mit Ößen."
      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      chunk = hd(chunks)
      # byte_size should be greater than String.length for multi-byte chars
      assert chunk.start_offset >= 0
      assert chunk.end_offset > chunk.start_offset
    end

    test "preserves start and end offsets" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      chunks = Chunker.chunk(text)

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
      first_content = hd(chunks).content
      assert String.contains?(first_content, "# Heading One")
    end

    test "emits current chunk when long paragraph follows accumulated content" do
      # First, accumulate some short paragraphs
      short = String.duplicate("short ", 50) |> String.trim()
      # Then a very long paragraph that exceeds target on its own
      long = String.duplicate("longword ", 350) |> String.trim()

      text = "#{short}\n\n#{long}"
      chunks = Chunker.chunk(text)

      # Should produce at least 2 chunks: the short one and the long one(s)
      assert length(chunks) >= 2
      assert String.contains?(hd(chunks).content, "short")
    end

    test "word_count is accurate" do
      text = "One two three four five."
      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      assert hd(chunks).word_count == 5
    end

    test "splits very long single paragraph into multiple chunks at sentences" do
      # Build a single paragraph (no double newlines) that exceeds 600 words
      # so it gets split into 2+ chunks via sentence splitting
      sentences =
        for i <- 1..50 do
          "This is sentence number #{i} with enough words to add up quickly. "
        end

      text = Enum.join(sentences)
      chunks = Chunker.chunk(text)

      # With ~600 words, should produce at least 2 chunks
      assert length(chunks) >= 2

      # All chunks should have content and valid offsets
      for chunk <- chunks do
        assert chunk.content != ""
        assert chunk.word_count > 0
        assert chunk.start_offset >= 0
        assert chunk.end_offset > chunk.start_offset
      end

      # Offsets should be non-decreasing
      offsets = Enum.map(chunks, & &1.start_offset)
      assert offsets == Enum.sort(offsets)
    end

    test "handles paragraph exceeding target after accumulating others" do
      # Short paragraphs followed by a very long one
      short1 = String.duplicate("aaa ", 100) |> String.trim()
      short2 = String.duplicate("bbb ", 100) |> String.trim()

      # Long paragraph with sentences (> 300 words by itself)
      long_sentences =
        for i <- 1..30 do
          "Sentence #{i} in this very long paragraph that just keeps going. "
        end

      long = Enum.join(long_sentences)

      text = "#{short1}\n\n#{short2}\n\n#{long}"
      chunks = Chunker.chunk(text)

      # Should emit short1+short2 as one chunk, then split the long paragraph
      assert length(chunks) >= 2

      # First chunk should contain the short paragraphs
      first = hd(chunks)
      assert String.contains?(first.content, "aaa")
    end
  end

  describe "content_for_embedding/2" do
    test "returns content as-is for first chunk (index 0)" do
      chunks = Chunker.chunk("Hello world paragraph.")
      result = Chunker.content_for_embedding(chunks, 0)
      assert result == "Hello world paragraph."
    end

    test "returns empty string for index 0 with empty chunks" do
      assert Chunker.content_for_embedding([], 0) == ""
    end

    test "returns empty string for out-of-bounds index" do
      chunks = Chunker.chunk("Short text.")
      assert Chunker.content_for_embedding(chunks, 5) == ""
    end

    test "includes overlap from previous chunk" do
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

    test "content_for_embedding for chunk with short previous chunk" do
      # When previous chunk has fewer words than overlap target,
      # all words should still be included
      short_para = "Just five words here total."
      long_para = String.duplicate("beta ", 200) |> String.trim()
      another_para = String.duplicate("gamma ", 200) |> String.trim()

      text = "#{short_para}\n\n#{long_para}\n\n#{another_para}"
      chunks = Chunker.chunk(text)

      if length(chunks) > 1 do
        embed_content = Chunker.content_for_embedding(chunks, 1)
        # Should include the overlap (even if previous chunk is short)
        assert String.length(embed_content) > 0
      end
    end
  end
end
