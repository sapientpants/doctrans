defmodule Doctrans.Search.ChunkerTest do
  use ExUnit.Case, async: true

  alias Doctrans.Search.Chunker

  # The limits `Chunker` documents. They are stated here rather than imported
  # because a test that read the module's own attributes would agree with it by
  # construction and could not catch a limit being raised to fit a defect.
  @target_words 300
  @max_words 400
  @max_graphemes 3200
  @max_bytes 12_800

  # The overlap bound, plus the two graphemes of the join between it and the
  # chunk it is prepended to.
  @max_overlap_graphemes 402

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
      # Then a very long paragraph that exceeds target on its own. It has to
      # exceed the *ceiling*, not the target: a 350-word paragraph is one
      # segment the packer is entitled to emit whole, so a fixture that size
      # produces the same two chunks whether or not it was ever split, which is
      # what left this test passing on the defect it was written for.
      long = String.duplicate("longword ", 800) |> String.trim()

      text = "#{short}\n\n#{long}"
      chunks = Chunker.chunk(text)

      assert String.contains?(hd(chunks).content, "short")

      # The intro, plus a paragraph that cannot be fewer than two chunks.
      assert length(chunks) >= 3
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

      # The count is deterministic, so it is asserted rather than bounded: the
      # intro, then the paragraph filled to the target and spilling a remainder.
      assert length(chunks) == 9
      assert Enum.map(chunks, & &1.word_count) == [2, 300, 300, 300, 277, 266, 266, 266, 25]
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

      assert length(chunks) == 11
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

      assert length(chunks) == 3
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
      # The leading whitespace matters: offsets are built against the trimmed
      # text, so without adding back what the trim removed they address a string
      # the caller never passed in. Asserting against `text` rather than against
      # `String.trim(text)` is what pins that.
      text =
        "  \n\n " <>
          "Intro paragraph.\n\n" <>
          Enum.map_join(1..400, "  ", &"This is sentence #{&1}.")

      chunks = Chunker.chunk(text)

      assert length(chunks) > 2

      for chunk <- chunks do
        assert binary_part(
                 text,
                 chunk.start_offset,
                 chunk.end_offset - chunk.start_offset
               ) == chunk.content
      end
    end

    test "chunk indexes stay contiguous and offsets non-decreasing across a split" do
      chunks = Chunker.chunk("Intro.\n\n" <> words(2000))

      # Bounding the count first: indexing and ordering hold trivially when the
      # paragraph was never split, which is how this passed against the code the
      # fix replaced.
      assert length(chunks) > 2
      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1))
      starts = Enum.map(chunks, & &1.start_offset)
      assert starts == Enum.sort(starts)
      assert starts == Enum.uniq(starts)
    end

    test "a chunk may pass the fill target but never the ceiling" do
      # Two sentences of 350 words. Each is a single segment, over the target
      # and under the ceiling, so the packer emits each whole -- the only shape
      # that reaches the 301-400 band at all. Without it nothing in this file
      # exercises the ceiling the limits are stated in.
      text = words(350) <> ". " <> Enum.map_join(351..700, " ", &"word#{&1}") <> "."

      chunks = Chunker.chunk(text)

      assert Enum.map(chunks, & &1.word_count) == [350, 350]
      assert Enum.any?(chunks, &(&1.word_count > @target_words))
      assert_within_limits(chunks)
    end

    test "a chunk of many-byte graphemes is bounded in bytes, not only graphemes" do
      # A family emoji is one grapheme built from four joined codepoints, 25
      # bytes each. 3,200 of them sit inside the grapheme ceiling at 80,000
      # bytes -- and bytes are what the embedding server is handed.
      text =
        String.duplicate("👨‍👩‍👧‍👦", 3200)

      chunks = Chunker.chunk(text)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.valid?(&1.content))
      assert_within_limits(chunks)
      assert_preserves(text, chunks)
    end

    test "every terminator the pattern lists ends a chunk" do
      # Seven of the eight terminators were listed in the pattern and exercised
      # by nothing, so only the Latin full stop was ever known to work.
      for {terminator, sentence} <- [
            {"…", "Trailing off… "},
            {"。", "これは文です。"},
            {"！", "すごい！"},
            {"？", "本当に？"},
            {"।", "यह वाक्य है। "},
            {"॥", "श्लोक॥ "},
            {"۔", "یہ جملہ ہے۔ "},
            {"؟", "هل هذا سؤال؟ "}
          ] do
        chunks = Chunker.chunk(String.duplicate(sentence, 800))

        assert length(chunks) > 1, "#{terminator} produced a single chunk"
        assert_within_limits(chunks)

        assert Enum.all?(
                 chunks,
                 &String.ends_with?(String.trim_trailing(&1.content), terminator)
               ),
               "#{terminator} left a chunk ending mid-sentence"
      end
    end

    test "short sentences in a space-free script still fill a chunk" do
      # 2,000 two-character sentences. Counting words by summing the segments
      # counts the word they meet in twice -- a zero-width boundary leaves no
      # whitespace between them -- so the word budget would bind after 300
      # sentences and cut these chunks to a quarter of the grapheme budget the
      # script is actually held to.
      text = String.duplicate("あ。", 2000)

      chunks = Chunker.chunk(text)

      assert Enum.map(chunks, &String.length(&1.content)) == [2400, 1600]
      assert_within_limits(chunks)
      assert_preserves(text, chunks)
    end

    test "offsets slice back out of the source across separators and scripts" do
      # The round-trip as a property over varied sources rather than one
      # fixture. Each is a single oversized paragraph, which is the region the
      # span rewrite covers; grouped paragraphs are Q04, below.
      sources = [
        words(2000),
        "Intro.\n\n" <> words(2000),
        "   \n\n  " <> words(2000),
        Enum.map_join(1..400, "  ", &"This is sentence #{&1}."),
        Enum.map_join(
          1..400,
          "",
          &"これは第#{&1}番目です。"
        ),
        Enum.map_join(1..400, " ", &"Über den Hügel lief der Hund Nummer #{&1}."),
        String.duplicate("é", 5000),
        String.duplicate(
          "यह एक वाक्य है। ",
          400
        )
      ]

      for source <- sources do
        chunks = Chunker.chunk(source)
        assert chunks != []

        for chunk <- chunks do
          assert binary_part(source, chunk.start_offset, chunk.end_offset - chunk.start_offset) ==
                   chunk.content
        end
      end
    end

    @tag skip: "PLAN.md Q04: finalize_paras/1 rejoins paragraphs on a literal \"\\n\\n\""
    test "offsets slice back out of the source for grouped paragraphs" do
      # The half of Q04 this change did not touch, recorded so it fails the day
      # it is fixed rather than being rediscovered. The span covers the source's
      # three newlines; the content was rebuilt with two.
      source = "aaa bbb\n\n\nccc ddd\n\n\neee fff"

      [chunk] = Chunker.chunk(source)

      assert binary_part(source, chunk.start_offset, chunk.end_offset - chunk.start_offset) ==
               chunk.content
    end

    test "text that is not valid UTF-8 is chunked rather than raising" do
      # The splitting path runs a Unicode regex, which raises on a stray byte.
      # Postgres rejects these before they reach a page, but a raise here is
      # taken by an Oban job that retries it deterministically and leaves the
      # page marked "processing" for good.
      text = words(2000) <> " " <> <<0xE6>>

      chunks = Chunker.chunk(text)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.valid?(&1.content))
    end
  end

  describe "content_for_embedding/2 overlap bounds" do
    test "overlap is bounded for text that does not separate words with spaces" do
      japanese =
        Enum.map_join(
          1..400,
          "",
          &"これは第#{&1}番目です。"
        )

      chunks = Chunker.chunk(japanese)

      assert length(chunks) > 1

      # The word tail sees one word in a Japanese chunk and so returns all of
      # it: a 2,394-grapheme chunk went to the embedding server as 4,794, twice
      # the ceiling this module advertises.
      for index <- 1..(length(chunks) - 1) do
        chunk = Enum.at(chunks, index)
        embedded = Chunker.content_for_embedding(chunks, index)

        assert String.contains?(embedded, chunk.content)

        assert String.length(embedded) <= String.length(chunk.content) + @max_overlap_graphemes,
               "overlap for chunk #{index} was not bounded"
      end
    end

    test "overlap for space-separated text is unchanged" do
      text = String.duplicate("alpha ", 400) <> "\n\n" <> String.duplicate("beta ", 400)
      chunks = Chunker.chunk(text)

      assert length(chunks) > 1

      embedded = Chunker.content_for_embedding(chunks, 1)

      # Still a 50-word tail: the grapheme bound is loose enough not to bite on
      # words this size.
      assert embedded |> String.split(~r/\s+/, trim: true) |> length() ==
               Enum.at(chunks, 1).word_count + 50
    end
  end

  defp words(n), do: Enum.map_join(1..n, " ", &"word#{&1}")

  defp assert_within_limits(chunks) do
    assert chunks != []

    for chunk <- chunks do
      assert chunk.word_count <= @max_words
      assert String.length(chunk.content) <= @max_graphemes
      assert byte_size(chunk.content) <= @max_bytes
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
