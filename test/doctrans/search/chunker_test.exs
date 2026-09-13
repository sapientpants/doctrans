defmodule Doctrans.Search.ChunkerTest do
  use ExUnit.Case, async: true

  alias Doctrans.Search.Chunker

  # The limits `Chunker` documents. They are stated here rather than imported
  # because a test that read the module's own attributes would agree with it by
  # construction and could not catch a limit being raised to fit a defect.
  @max_words 400
  @max_graphemes 3200

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

      # `length(chunks) >= 2` alone passed on the defect this test was written
      # for: the intro and the whole 350-word paragraph are two chunks. What
      # distinguishes a split paragraph from an unsplit one is the size of the
      # largest chunk.
      assert Enum.all?(chunks, &(&1.word_count <= @max_words))
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

      # The long paragraph really is split, rather than emitted whole after the
      # short ones are flushed -- which is what the assertions above allowed.
      assert Enum.all?(chunks, &(&1.word_count <= @max_words))
      assert length(chunks) >= 3
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

  describe "oversized paragraphs" do
    test "a long paragraph after an introduction is split rather than emitted whole" do
      # The probe PLAN.md S04 recorded: a two-word intro then a 2,000-word
      # paragraph, which produced [2, 2000] against a 300-word target because a
      # paragraph was only ever split when nothing preceded it.
      text = "Short intro.\n\n" <> words(2000)

      chunks = Chunker.chunk(text)

      assert length(chunks) > 2
      assert_within_limits(chunks)
      assert_preserves(text, chunks)
    end

    test "sentence-free text is split" do
      # Not one terminator anywhere, so there is no sentence boundary to split
      # on and the word-level fallback is the only thing that can bound this.
      chunks = Chunker.chunk(words(2000))

      assert length(chunks) > 1
      assert_within_limits(chunks)
    end

    test "a single sentence longer than the limit is split" do
      chunks = Chunker.chunk(words(2000) <> ".")

      assert length(chunks) > 1
      assert_within_limits(chunks)
    end

    test "a run with no whitespace at all is split at grapheme boundaries" do
      # No paragraph break, no sentence break, and no word break either: the
      # last fallback is the only one that applies.
      chunks = Chunker.chunk(String.duplicate("a", 5000))

      assert length(chunks) > 1
      assert_within_limits(chunks)
    end

    test "splitting a multi-byte run never produces invalid UTF-8" do
      # Cutting a 2-byte character down the middle would yield content that is
      # not a valid string, which is why the fallback counts graphemes.
      chunks = Chunker.chunk(String.duplicate("é", 5000))

      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.valid?(&1.content))
      assert_within_limits(chunks)
      assert_preserves(String.duplicate("é", 5000), chunks)
    end

    test "sentences are found in scripts the English pattern could not match" do
      # The old boundary required an ASCII capital after the terminator, so a
      # German sentence opening on an umlaut never started one and the whole
      # passage stayed a single chunk.
      german = Enum.map_join(1..400, " ", &"Über den Hügel lief der Hund Nummer #{&1}.")

      chunks = Chunker.chunk(german)

      assert length(chunks) > 1
      assert_within_limits(chunks)
      assert_preserves(german, chunks)

      # Size alone does not prove the sentences were found: the word-level
      # fallback bounds this passage either way, just by cutting mid-sentence.
      # Every chunk ending on a terminator is what says the boundary matched.
      assert Enum.all?(chunks, &String.ends_with?(&1.content, "."))
    end

    test "text that does not separate words with spaces stays within the grapheme limit" do
      # Japanese writes no spaces, so every word-based budget sees one word
      # however long the passage is. Only a grapheme budget bounds this.
      japanese = Enum.map_join(1..400, "", &"これは第#{&1}番目の文です。")

      chunks = Chunker.chunk(japanese)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(&1.word_count == 1))
      assert_within_limits(chunks)
      assert_preserves(japanese, chunks)

      # And the ideographic full stop is a sentence boundary, so the split
      # lands between sentences rather than inside one.
      assert Enum.all?(chunks, &String.ends_with?(&1.content, "。"))
    end

    test "offsets locate a split chunk in the source text" do
      # Chunks from a split paragraph are contiguous byte spans, so each one
      # slices back out of the source exactly. The previous implementation
      # rejoined sentences with a single space and advanced the offset by the
      # length of that join, so every chunk after the first pointed at the
      # wrong bytes.
      text = "Intro paragraph.\n\n" <> Enum.map_join(1..400, "  ", &"This is sentence #{&1}.")
      trimmed = String.trim(text)

      chunks = Chunker.chunk(text)

      assert length(chunks) > 2

      for chunk <- chunks do
        assert binary_part(
                 trimmed,
                 chunk.start_offset,
                 chunk.end_offset - chunk.start_offset
               ) == chunk.content
      end
    end

    test "chunk indexes stay contiguous and offsets non-decreasing across a split" do
      chunks = Chunker.chunk("Intro.\n\n" <> words(2000))

      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1))
      starts = Enum.map(chunks, & &1.start_offset)
      assert starts == Enum.sort(starts)
    end
  end

  defp words(n), do: Enum.map_join(1..n, " ", &"word#{&1}")

  defp assert_within_limits(chunks) do
    assert chunks != []

    for chunk <- chunks do
      assert chunk.word_count <= @max_words
      assert String.length(chunk.content) <= @max_graphemes
    end
  end

  # Content survives a split: every non-whitespace character of the source is
  # still present, in order, across the chunks. Whitespace is excluded because
  # a split consumes the separator it breaks on, and words are not a usable
  # unit for scripts that do not space-separate them.
  defp assert_preserves(source, chunks) do
    strip = &String.replace(&1, ~r/\s+/u, "")
    assert chunks |> Enum.map_join("", & &1.content) |> then(strip) == strip.(String.trim(source))
  end
end
