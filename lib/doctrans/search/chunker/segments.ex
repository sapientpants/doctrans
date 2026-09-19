defmodule Doctrans.Search.Chunker.Segments do
  @moduledoc """
  The budgets a chunk is held to, and the splitting of text that passes them.

  `Doctrans.Search.Chunker` groups whole paragraphs; this is what it falls back
  to when one paragraph is larger than a chunk may be. Splitting is a ladder,
  because each rung can fail to apply: a paragraph is cut at sentence
  boundaries, a sentence still over the ceiling at word boundaries, and a word
  still over it at grapheme boundaries. The last rung always applies, which is
  what makes the budgets guarantees rather than targets.

  Everything here works in byte spans into the text rather than by joining
  strings back together, and a chunk is always one contiguous span. That is what
  makes `binary_part(text, start_offset, end_offset - start_offset)` return a
  chunk's content exactly: the separators between segments are inside the span,
  so nothing is reconstructed and nothing can drift (PLAN.md Q04). This holds
  within a split paragraph -- `Chunker` still rejoins whole paragraphs on a
  literal "\\n\\n" the source may not have, which is the half of Q04 that
  remains open.
  """

  # A chunk fills to the target and then takes whatever the current segment is,
  # so it can overshoot by one segment; the ceiling is what splits that segment
  # rather than letting it through. Every ceiling is 4/3 of its target.
  @target_words 300
  @max_words 400

  # Chinese, Japanese and Thai do not separate words with spaces, so
  # `word_count/1` reports 1 for a paragraph of any length and a word budget is
  # blind to it -- a 5,000-character page became one chunk. A grapheme budget is
  # the limit that still means something there.
  #
  # It rarely binds on space-separated prose, though "never" would be too
  # strong: 300 words of Latin text runs about 1,900 graphemes and 400 about
  # 2,500, so the grapheme target is what binds first at roughly 380 words of
  # ordinary English.
  @target_graphemes 2400
  @max_graphemes 3200

  # A grapheme is one user-visible character but any number of bytes, and the
  # embedding server is charged for what it receives: 3,200 emoji built from
  # zero-width joiners are 80,000 bytes. At 4 bytes per grapheme -- the most a
  # single codepoint takes in UTF-8 -- these bind on no ordinary text in any
  # script, only where one grapheme is many codepoints. A single grapheme
  # cluster larger than the ceiling is the one thing that can still pass it:
  # there is no rung below a character that does not produce mojibake.
  @target_bytes 9600
  @max_bytes 12_800

  # Guarded rather than asserted in prose: a ceiling at or below its target
  # would make the rung meant to admit a segment split it instead.
  if @max_words <= @target_words or @max_graphemes <= @target_graphemes or
       @max_bytes <= @target_bytes do
    raise "Chunker: every hard ceiling must exceed its fill target"
  end

  # Sentence boundaries across scripts. Latin terminators must be followed by
  # whitespace, so "3.14" and "example.com" stay intact; the full-width and
  # Indic terminators may not be, because those scripts do not put a space after
  # one. Requiring a capital after the terminator, as this pattern once did,
  # matches English and little else -- not German after "Über", not Russian, not
  # any sentence beginning lowercase, and no CJK at all.
  @sentence_boundary ~r/(?<=[.!?\x{2026}])\s+|(?<=[\x{3002}\x{FF01}\x{FF1F}\x{0964}\x{0965}\x{06D4}\x{061F}])\s*/u

  # The rung below sentences. Below this one there is only the character itself,
  # which `grapheme_spans/2` cuts.
  @word_boundary ~r/\s+/u

  # What `word_count/1`'s `\s` matches, spelled out for `:binary.match/2`.
  @ascii_whitespace [" ", "\t", "\n", "\v", "\f", "\r"]

  @typedoc "What every budget is expressed in: {words, graphemes, bytes}."
  @type measure :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "A chunk before it is indexed: {content, start_offset, end_offset}."
  @type raw_chunk :: {String.t(), non_neg_integer(), non_neg_integer()}

  # A byte span into the text being split: {start, length}.
  @typep span :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Splits an oversized paragraph into chunks that respect the budgets.

  `para_start` is the paragraph's own byte offset, which the returned offsets
  are relative to.
  """
  @spec split(String.t(), non_neg_integer()) :: [raw_chunk()]
  def split(text, para_start) do
    text
    |> segment_spans()
    |> group_spans(text, para_start)
  end

  # The units a chunk is assembled from: sentences, and -- where one sentence is
  # over the ceilings -- the words or graphemes it breaks into. Each rung can
  # fail to apply (a paragraph with no terminator in it, a sentence with no
  # space in it), so the last one cuts the characters themselves and always
  # applies. That is what makes the budgets guarantees rather than targets.
  # Each segment is measured once here and carries its measure to the packer,
  # which is the only thing that needs it.
  @spec segment_spans(String.t()) :: [{span(), measure()}]
  defp segment_spans(text) do
    text
    |> split_spans({0, byte_size(text)}, @sentence_boundary)
    |> Enum.flat_map(&bound(text, &1, [@word_boundary]))
  end

  defp bound(text, span, rungs) do
    measure = measure(slice(text, span))

    cond do
      within?(measure, :max) ->
        [{span, measure}]

      rungs == [] ->
        Enum.map(grapheme_spans(text, span), &{&1, measure(slice(text, &1))})

      true ->
        text
        |> split_spans(span, hd(rungs))
        |> Enum.flat_map(&bound(text, &1, tl(rungs)))
    end
  end

  # The runs of `span` between matches of `separator`, as absolute spans. The
  # separator is dropped, which is what keeps a terminator with the sentence it
  # ends while leaving the whitespace after it out.
  @spec split_spans(String.t(), span(), Regex.t()) :: [span()]
  defp split_spans(text, {start, len} = span, separator) do
    {spans, tail_start} =
      separator
      |> Regex.scan(slice(text, span), return: :index)
      |> Enum.map(&hd/1)
      |> Enum.reduce({[], 0}, &take_run/2)

    spans
    |> prepend_tail(tail_start, len)
    |> Enum.reverse()
    |> Enum.map(fn {pos, size} -> {start + pos, size} end)
  end

  defp take_run({pos, len}, {spans, from}) do
    if pos > from do
      {[{from, pos - from} | spans], pos + len}
    else
      # A separator at the very start of the span, or a zero-width match:
      # advance past it without emitting an empty run.
      {spans, max(from, pos + len)}
    end
  end

  defp prepend_tail(spans, tail_start, size) when tail_start < size do
    [{tail_start, size - tail_start} | spans]
  end

  defp prepend_tail(spans, _tail_start, _size), do: spans

  # A run with no whitespace to break on is cut into fixed runs at the fill
  # target, so each one is a whole chunk's worth. The cut is by grapheme rather
  # than by byte so it can never land inside a multi-byte character and produce
  # invalid UTF-8, and it watches the byte budget too, because a grapheme is not
  # a fixed number of bytes.
  @spec grapheme_spans(String.t(), span()) :: [span()]
  defp grapheme_spans(text, span) do
    {start, _len} = span

    {spans, open_start, _count, size} =
      text
      |> slice(span)
      |> String.graphemes()
      |> Enum.reduce({[], start, 0, 0}, &take_grapheme/2)

    spans
    |> prepend_span({open_start, size})
    |> Enum.reverse()
  end

  defp take_grapheme(grapheme, {spans, open_start, count, size}) do
    grapheme_size = byte_size(grapheme)

    if count > 0 and (count + 1 > @target_graphemes or size + grapheme_size > @target_bytes) do
      {[{open_start, size} | spans], open_start + size, 1, grapheme_size}
    else
      {spans, open_start, count + 1, size + grapheme_size}
    end
  end

  defp prepend_span(spans, {_start, 0}), do: spans
  defp prepend_span(spans, span), do: [span | spans]

  # Fill a chunk with segments until a budget is reached, then start the next.
  # Counts are carried forward rather than recomputed over the growing span:
  # re-measuring per segment made a sentence-dense document ~11x slower.
  defp group_spans(segments, text, para_start) do
    {chunks, open} = Enum.reduce(segments, {[], nil}, &pack_segment(&1, &2, text))

    chunks
    |> flush_open_span(open)
    |> Enum.reverse()
    |> Enum.map(&to_span_chunk(&1, text, para_start))
  end

  defp pack_segment({span, measure}, {chunks, nil}, _text), do: {chunks, {span, measure}}

  defp pack_segment({span, measure}, {chunks, {open, open_measure}}, text) do
    combined = combine(text, open, open_measure, span, measure)

    if within?(combined, :target) do
      {chunks, {union(open, span), combined}}
    else
      {[open | chunks], {span, measure}}
    end
  end

  # What the open span measures once extended over this segment, including the
  # separator between them that the combined span takes back in.
  defp combine(text, {open_start, open_len} = open, open_measure, {start, _len}, measure) do
    gap = {open_start + open_len, start - open_start - open_len}

    open_measure
    |> add(gap_measure(text, gap))
    |> add(measure)
    |> subtract_joined_word(text, open, start)
  end

  defp union({open_start, _open_len}, {start, len}), do: {open_start, start + len - open_start}

  # The bytes between two segments -- the separator the split dropped -- which
  # the combined span covers and so has to be counted.
  defp gap_measure(_text, {_start, 0}), do: zero()
  defp gap_measure(text, {_start, len} = gap), do: {0, grapheme_count(slice(text, gap)), len}

  # Graphemes and bytes are additive across a join; words are not. Where no
  # whitespace separates two segments -- which is what a zero-width sentence
  # boundary leaves behind, and what every grapheme-level cut leaves behind --
  # the word they meet in is one word, and summing counts it twice. Left
  # uncorrected this closes a CJK chunk after 300 sentences rather than at the
  # grapheme budget, cutting it to an eighth of its intended size.
  defp subtract_joined_word({words, graphemes, bytes}, text, {open_start, open_len}, start) do
    open_end = open_start + open_len
    junction = binary_part(text, open_end - 1, start - open_end + 2)

    # `:binary.match/2` rather than a regex because this runs once per segment,
    # and the whitespace it looks for is exactly what `word_count/1`'s non-
    # Unicode `\s` splits on.
    if :binary.match(junction, @ascii_whitespace) == :nomatch do
      {words - 1, graphemes, bytes}
    else
      {words, graphemes, bytes}
    end
  end

  defp flush_open_span(chunks, nil), do: chunks
  defp flush_open_span(chunks, {span, _measure}), do: [span | chunks]

  defp to_span_chunk({start, len}, text, para_start) do
    {slice(text, {start, len}), para_start + start, para_start + start + len}
  end

  defp slice(text, {start, len}), do: binary_part(text, start, len)

  @doc "What every budget is counted in."
  @spec measure(String.t()) :: measure()
  def measure(text), do: {word_count(text), grapheme_count(text), byte_size(text)}

  @doc "The measure of nothing at all."
  @spec zero() :: measure()
  def zero, do: {0, 0, 0}

  @doc "Sums two measures. Words are only additive across whitespace."
  @spec add(measure(), measure()) :: measure()
  def add({words, graphemes, bytes}, {more_words, more_graphemes, more_bytes}) do
    {words + more_words, graphemes + more_graphemes, bytes + more_bytes}
  end

  # One predicate over both budgets, so raising a limit cannot move one of them
  # and leave the other behind: :target is what fills a chunk, :max the ceiling
  # no chunk may pass.
  @spec within?(measure(), :target | :max) :: boolean()
  def within?({words, graphemes, bytes}, :target) do
    words <= @target_words and graphemes <= @target_graphemes and bytes <= @target_bytes
  end

  def within?({words, graphemes, bytes}, :max) do
    words <= @max_words and graphemes <= @max_graphemes and bytes <= @max_bytes
  end

  @doc "Whitespace-separated runs, which is one for a script that writes none."
  @spec word_count(String.t()) :: non_neg_integer()
  def word_count(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp grapheme_count(text), do: String.length(text)
end
