defmodule Doctrans.Search.ChunkerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Doctrans.Search.Chunker

  # The limits `Chunker` documents. They are stated here rather than imported
  # because a test that read the module's own attributes would agree with it by
  # construction and could not catch a limit being raised to fit a defect.
  @target_words 300
  @max_words 400
  @max_graphemes 3200
  @max_bytes 12_800

  # The fill targets the generator sizes a paragraph against, so it lands on
  # the intended side of them whatever script it is written in.
  @target_graphemes 2400
  @target_bytes 9600

  # One token per script family Q04 names, so a generated document mixes byte
  # widths (1, 2, 3 and 4 bytes per codepoint), a grapheme cluster built from
  # joined codepoints, and a script that separates no words with spaces.
  @tokens ["word", "Ubermassig", "Übermäßig", "文書", "वाक्य", "👨‍👩‍👧‍👦"]

  # Whitespace runs inside one paragraph: a single newline does not start a new
  # one. Two of these are sentence terminators, so the split ladder's top rung
  # is reachable.
  @intra_separators [" ", "  ", "\t", "\n", " \n ", ". ", "。"]

  # What separates two paragraphs. Every one of these is a paragraph break and
  # all but the first are longer than the two bytes `finalize_paras/1` used to
  # rebuild the join from -- which is the bug this property exists to catch.
  @paragraph_separators ["\n\n", "\n\n\n", "\n\n\n\n\n", "\n \n\n", "\n\n\t\n", "\n\n   \n\n"]

  # Leading and trailing whitespace on the document itself: `chunk/1` trims it
  # and has to add the leading run back to every offset it reports.
  @document_edges ["", " ", "\n", "\t\n", "  \n\n ", "\n\n\n"]

  # The overlap bound, plus the two graphemes of the join between it and the
  # chunk it is prepended to.
  @max_overlap_graphemes 402

  # The same bound in bytes. `overlap_tail/1` is capped in both units because
  # one many-byte grapheme cluster passes the byte budget long before the
  # grapheme one, and only the grapheme half was pinned before.
  @max_overlap_bytes 1602

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

    test "whitespace between grouped paragraphs counts against the budget" do
      # A grouped chunk's content is the whole span from its first paragraph to
      # its last, so the blank lines inside it are stored and have to be
      # budgeted for. Sixty short paragraphs separated by 504-byte whitespace
      # runs are 60 words in 30 KB: budgeting the separator as the two bytes of
      # a "\n\n" join makes the lot one chunk, 2.3x the byte ceiling and 9.4x
      # the grapheme ceiling this module documents.
      gap = "\n\n" <> String.duplicate(" ", 500) <> "\n\n"
      text = Enum.map_join(1..60, gap, &"para#{&1}")

      chunks = Chunker.chunk(text)

      assert length(chunks) > 1
      assert_within_limits(chunks)
    end

    test "a gap of whitespace word_count/1 does not recognise stays within the word ceiling" do
      # `word_count/1` splits on ASCII whitespace, so a line holding only a
      # non-breaking space -- what an HTML-to-markdown conversion makes of
      # `<p>&nbsp;</p>` -- is a word to it. Those lines are in a grouped chunk's
      # span, so counting the gap as zero words undercounts the chunk by one per
      # spacer: 500 of them between two paragraphs made a single 501-word chunk
      # against a ceiling of 400.
      nbsp = List.to_string([0xA0])
      text = "alpha" <> String.duplicate(nbsp <> "\n\n", 500) <> "beta"

      chunks = Chunker.chunk(text)

      assert_within_limits(chunks)
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
  end

  describe "oversized paragraphs" do
    test "a long paragraph after an introduction is split rather than emitted whole" do
      # The probe that found this: a two-word intro then a 2,000-word
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

    test "offsets slice back out of the source for grouped paragraphs" do
      # The second half of Q04: the span covers the source's three newlines, and
      # the content used to be rebuilt with two.
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

  describe "offsets round-trip (property)" do
    # The three tests this replaces asserted `start_offset >= 0` and
    # `end_offset > start_offset` on single-chunk inputs, which no offset
    # arithmetic can fail. What the offsets are for is locating the chunk in the
    # page, so that is what is asserted, over generated documents rather than
    # one hand-written string.
    property "every chunk slices back out of the source text" do
      # 50 runs rather than the default 100: a generated document runs about
      # 1 KB at the median, 31 KB at the 95th percentile and 68 KB at the
      # largest seen over a thousand draws, and the paragraph shapes here are
      # few enough to be covered well inside 50. Runs are kept low deliberately
      # so the suite stays fast.
      check all(text <- document(), max_runs: 50) do
        chunks = Chunker.chunk(text)

        # Without this the property is vacuous for any document that chunks to
        # nothing, and the generator is built so none does.
        assert chunks != []

        for chunk <- chunks do
          assert binary_part(text, chunk.start_offset, chunk.end_offset - chunk.start_offset) ==
                   chunk.content,
                 "chunk #{chunk.chunk_index} of #{length(chunks)} does not slice back out"
        end

        # Slicing the span rather than rejoining puts the blank lines between
        # grouped paragraphs into the stored content, so the ceilings are
        # asserted over the same generated documents.
        assert_within_limits(chunks)
      end
    end
  end

  describe "chunk/1 invariants (properties)" do
    # The invariants the fixtures above state only by example, as siblings of
    # the round-trip property over the same `document/0` generator and the same
    # `max_runs: 50` bound. All three guard the three-way `cond`
    # in `accumulate_paragraph/3`: a branch that flushed the wrong accumulator
    # drops, duplicates or reorders whole paragraphs, and only a fixed source
    # said so before.

    # C01's "retain every passage", as an invariant. Literal word-multiset
    # equality -- what Q05 names -- does *not* hold: asserting it fails on 163
    # of 2,000 generated documents, shrinking to `String.duplicate("word。",
    # 481)`. A space-free run is one word to `word_count/1` however long it is,
    # and `Segments`' `@sentence_boundary` cuts after a full-width terminator on
    # a zero-width match, so one source word becomes two chunk words with not a
    # character lost. The junction is what says so, and it is the only repair
    # needed: a split consumes the whitespace it breaks on, and over 2,000
    # documents no junction held anything but whitespace or nothing at all.
    # Sequences are compared rather than multisets because it costs nothing and
    # is strictly stronger -- a multiset would not notice chunks coming back in
    # the wrong order. This supersedes `assert_preserves/2`, which strips
    # whitespace and so cannot tell a word cut in two from one left whole; the
    # example tests keep it for the fixed sources they pin.
    property "every word of the source survives into exactly one chunk" do
      check all(text <- document(), max_runs: 50) do
        chunks = Chunker.chunk(text)

        # Without this the property is vacuous for any document that chunks to
        # nothing, and the generator is built so none does.
        assert chunks != []

        assert chunk_words(chunks) == split_words(String.trim(text)),
               "the #{length(chunks)} chunks do not hold the source's words"
      end
    end

    test "a chunk boundary in a space-free run re-tokenises a word rather than losing one" do
      # The counterexample the multiset form shrinks to, kept as the regression
      # example: 2,405 graphemes with no whitespace anywhere, so the source is a
      # single word and the two chunks are a word each. Nothing is lost -- the
      # junction between them is zero bytes wide.
      text = String.duplicate("word。", 481)

      chunks = Chunker.chunk(text)

      assert length(chunks) == 2
      assert length(split_words(text)) == 1
      assert Enum.map(chunks, & &1.word_count) == [1, 1]
      assert Enum.at(chunks, 0).end_offset == Enum.at(chunks, 1).start_offset
      assert chunk_words(chunks) == split_words(text)
    end

    property "chunk indexes run from zero without a gap" do
      check all(text <- document(), max_runs: 50) do
        chunks = Chunker.chunk(text)

        assert chunks != []

        assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1)),
               "chunk indexes are not 0..#{length(chunks) - 1}"
      end
    end

    property "chunks are ordered and never overlap" do
      check all(text <- document(), max_runs: 50) do
        chunks = Chunker.chunk(text)

        assert chunks != []

        starts = Enum.map(chunks, & &1.start_offset)
        assert starts == Enum.sort(starts), "start offsets are not non-decreasing"

        # The stronger half: a chunk starts at or after the previous one ends.
        # Stored content carries no overlap by construction -- that is what
        # `content_for_embedding/2` exists to add -- so two chunks sharing a
        # byte is a defect, and equal starts would mean an empty chunk.
        for [previous, chunk] <- Enum.chunk_every(chunks, 2, 1, :discard) do
          assert chunk.start_offset >= previous.end_offset,
                 "chunk #{chunk.chunk_index} starts before chunk #{previous.chunk_index} ends"
        end
      end
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

  describe "content_for_embedding/2 invariants (properties)" do
    # What goes to the embedding server, against the same `document/0`
    # generator and the same `max_runs: 50` bound as the properties above
    # This is the embedded-versus-stored divergence surface from
    # C01: the stored `content` is overlap-free and this is the only place the
    # two are allowed to differ, so the shape of the difference is what is
    # pinned -- the chunk's own content, whole, at the end, with at most a
    # bounded prefix in front of it.
    #
    # The example it replaces was "content_for_embedding for chunk with short
    # previous chunk", which wrapped its body in `if length(chunks) > 1` and
    # then asserted `String.length(embed_content) > 0`. It could go vacuous and
    # its assertion could not fail; short previous chunks are what
    # `short_paragraph/0` generates, so the property covers the case properly.
    #
    # Asserting this found the defect it now guards: `overlap_tail/1` rejoined
    # the tail's words on a literal `" "`, so the prefix was a suffix of the
    # previous chunk only when every separator inside it was a single space --
    # 1,206 of 2,133 consecutive chunk pairs over 2,000 generated documents
    # failed. `chunker.ex` is fixed; the two examples below pin the shrunk
    # counterexamples.
    property "the embedded text is the chunk's own content with a bounded prefix" do
      check all(text <- document(), max_runs: 50) do
        chunks = Chunker.chunk(text)

        # Without this the property is vacuous for any document that chunks to
        # nothing, and the generator is built so none does.
        assert chunks != []

        # Nothing precedes the first chunk, so it is embedded exactly as
        # stored. Asserted separately because it is the one index with its own
        # function clause.
        assert Chunker.content_for_embedding(chunks, 0) == hd(chunks).content

        # An index past the end has no chunk to embed and must not fall through
        # to a neighbour's content; `Indexer` reads `chunk.chunk_index` back
        # from the database, so the guard is against a stale row, not a typo.
        assert Chunker.content_for_embedding(chunks, length(chunks)) == ""

        for chunk <- chunks do
          embedded = Chunker.content_for_embedding(chunks, chunk.chunk_index)

          # The chunk itself always survives whole and last. Overlap is context
          # for what follows it, so anything that truncated the chunk, reversed
          # the join, or embedded a neighbour instead would lose the text the
          # vector is supposed to be of.
          assert String.ends_with?(embedded, chunk.content),
                 "chunk #{chunk.chunk_index} of #{length(chunks)} is not the end of what is embedded"

          # And the prefix in front of it is text that actually precedes it in
          # the page. A suffix of the previous chunk is the whole of what
          # overlap may be -- the embedded and the stored text are allowed to
          # differ only by context the reader would have had anyway, so a
          # prefix that appears nowhere in the source is a vector of something
          # the page does not say.
          #
          # Nothing precedes chunk 0, so the only suffix it may carry is the
          # empty one -- which is what makes this assertion unconditional
          # rather than skipped for the first chunk.
          previous =
            if chunk.chunk_index == 0,
              do: "",
              else: Enum.at(chunks, chunk.chunk_index - 1).content

          assert String.ends_with?(previous, prefix(embedded, chunk)),
                 "the overlap on chunk #{chunk.chunk_index} is not a suffix of what precedes it"

          # Bounded in both units, for the reason the chunk itself is: the word
          # tail alone is the whole of a chunk in a script that separates no
          # words, and a grapheme built of many codepoints passes the byte
          # budget long before the grapheme one.
          assert String.length(embedded) <= String.length(chunk.content) + @max_overlap_graphemes,
                 "overlap for chunk #{chunk.chunk_index} was not bounded in graphemes"

          assert byte_size(embedded) <= byte_size(chunk.content) + @max_overlap_bytes,
                 "overlap for chunk #{chunk.chunk_index} was not bounded in bytes"
        end
      end
    end

    test "a newline inside the previous chunk survives into the overlap" do
      # The counterexample the property shrank to, kept as the regression
      # example: two chunks, and the first holds one newline. The old
      # `Enum.join(" ")` embedded chunk 1 behind the prefix `"a b"` while the
      # stored chunk 0 read `"a\nb"`.
      chunks = Chunker.chunk("a\nb\n\n" <> words(300))

      assert length(chunks) == 2
      assert Enum.at(chunks, 0).content == "a\nb"
      assert prefix(Chunker.content_for_embedding(chunks, 1), Enum.at(chunks, 1)) == "a\nb"
    end

    test "the blank lines inside a grouped chunk survive into the overlap" do
      # The same defect on the shape Q04 created: a grouped chunk's content is
      # the source span, so it carries the real `"\n\n\n"` between its
      # paragraphs, and rejoining its words flattened that to one space.
      chunks = Chunker.chunk("aaa\n\n\nbbb\n\n" <> words(300))

      assert length(chunks) == 2
      assert Enum.at(chunks, 0).content == "aaa\n\n\nbbb"

      assert prefix(Chunker.content_for_embedding(chunks, 1), Enum.at(chunks, 1)) ==
               "aaa\n\n\nbbb"
    end
  end

  defp document do
    gen all(
          lead <- member_of(@document_edges),
          paras <- list_of(paragraph(), min_length: 1, max_length: 4),
          seps <- list_of(member_of(@paragraph_separators), length: length(paras) - 1),
          trail <- member_of(@document_edges)
        ) do
      lead <> interleave(paras, seps) <> trail
    end
  end

  # Mostly short paragraphs, so a document usually groups several into one
  # chunk -- the case the literal join broke -- with a long one often enough to
  # exercise the split path alongside it, and a medium one for the branch
  # neither reaches.
  defp paragraph do
    frequency([{3, short_paragraph()}, {3, medium_paragraph()}, {1, long_paragraph()}])
  end

  defp short_paragraph do
    gen all(
          tokens <- list_of(member_of(@tokens), min_length: 1, max_length: 25),
          seps <- list_of(member_of(@intra_separators), length: length(tokens) - 1)
        ) do
      interleave(tokens, seps)
    end
  end

  # A paragraph that fits a chunk on its own but not beside another one. That
  # is the only way to reach the third branch of `accumulate_paragraph/3`'s
  # cond, the one that flushes an accumulation and starts the next chunk with
  # this paragraph: the short shape above tops out near 100 words for a whole
  # document, well under the 300-word fill target, and anything larger is a
  # `long_paragraph`, which takes the split branch instead. Without this shape
  # the branch was reached by no generated document at all -- deleting its
  # flush, so it drops what it has accumulated, left all four properties here
  # passing.
  defp medium_paragraph do
    gen all(
          token <- member_of(@tokens),
          sep <- member_of(@intra_separators)
        ) do
      unit = token <> sep

      # Half of whichever budget binds first for this unit, so one paragraph is
      # inside the fill target and two of them are outside it whatever the
      # script. Words are one of the three because they are what binds for
      # ordinary prose, and graphemes and bytes because they are what binds for
      # a script that separates no words and for a grapheme built of many
      # codepoints.
      budget =
        Enum.min([
          @target_words,
          div(@target_graphemes, String.length(unit)),
          div(@target_bytes, byte_size(unit))
        ])

      String.duplicate(unit, div(budget, 2) + 1)
    end
  end

  # A paragraph over the fill target, whatever script it is in: repeating the
  # unit past the grapheme target passes that budget for a space-free script and
  # the word or byte budget well before it for the others.
  defp long_paragraph do
    gen all(
          token <- member_of(@tokens),
          sep <- member_of(@intra_separators)
        ) do
      unit = token <> sep
      String.duplicate(unit, div(@target_graphemes, String.length(unit)) + 1)
    end
  end

  defp interleave([first | rest], seps) do
    seps
    |> Enum.zip(rest)
    |> Enum.reduce(first, fn {sep, part}, acc -> acc <> sep <> part end)
  end

  defp words(n), do: Enum.map_join(1..n, " ", &"word#{&1}")

  # What `content_for_embedding/2` put in front of the chunk: its result with
  # the chunk's own content and the two-newline join taken back off the end.
  # `String.replace_suffix/3` leaves the string alone when the suffix is not
  # there, so this is only meaningful once the result is known to end with the
  # chunk -- which the assertion above it establishes.
  defp prefix(embedded, chunk) do
    embedded
    |> String.replace_suffix(chunk.content, "")
    |> String.replace_suffix("\n\n", "")
  end

  defp split_words(text), do: String.split(text, ~r/\s+/u, trim: true)

  # The source's words as the chunks hold them. Every chunk is a contiguous
  # span with no whitespace at either end, so its own words need no repair; the
  # one thing that does is a junction of zero bytes, where the source ran a word
  # straight across the chunk boundary and splitting it produced two. Joining
  # those two back is what makes this comparable to the source word for word.
  defp chunk_words(chunks) do
    chunks
    |> Enum.reduce({[], nil}, fn chunk, {acc, previous_end} ->
      words = split_words(chunk.content)

      if previous_end == chunk.start_offset do
        {join_last(acc, words), chunk.end_offset}
      else
        {acc ++ words, chunk.end_offset}
      end
    end)
    |> elem(0)
  end

  defp join_last(acc, [first | rest]), do: List.update_at(acc, -1, &(&1 <> first)) ++ rest

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
