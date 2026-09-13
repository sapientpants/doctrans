defmodule Doctrans.Search.Chunker do
  @moduledoc """
  Splits markdown text into overlapping chunks for fine-grained embedding.

  Respects paragraph boundaries (double newlines). Targets ~300 words per
  chunk with ~50-word overlap between consecutive chunks. A paragraph over the
  target is split at sentence boundaries, and a sentence still over it is split
  at word and then grapheme boundaries, so no chunk can exceed the hard limits
  below whatever the source looks like.
  """

  # Target ~300 words per chunk for fine-grained retrieval while
  # preserving enough context for meaningful embeddings.
  @target_words 300
  @overlap_words 50

  # The ceiling a chunk may not pass. A chunk fills to @target_words and then
  # takes whatever the current segment is, so it can overshoot by one segment;
  # the hard limit is what splits that segment rather than letting it through.
  @max_words 400

  # Chinese, Japanese and Thai do not separate words with spaces, so
  # `word_count/1` reports 1 for a paragraph of any length and every
  # word-based budget above is blind to it -- a 5,000-character page became one
  # chunk. A grapheme budget is the limit that still means something there.
  #
  # It is deliberately loose enough never to bind on space-separated prose:
  # 300 words of Latin text runs about 1,800 graphemes and 400 words about
  # 2,400, so these thresholds are reached first only when word counting has
  # stopped working.
  @target_graphemes 2400
  @max_graphemes 3200

  # Sentence boundaries across scripts. Latin terminators must be followed by
  # whitespace, so "3.14" and "example.com" stay intact; the full-width and
  # Indic terminators may not be, because those scripts do not put a space
  # after one. The previous pattern required an ASCII capital next, so it split
  # English and nothing else -- not German after "Über", not Russian, not any
  # sentence beginning lowercase, and not CJK, which has no ASCII capitals at
  # all.
  @sentence_boundary ~r/(?<=[.!?\x{2026}])\s+|(?<=[\x{3002}\x{FF01}\x{FF1F}\x{0964}\x{0965}\x{06D4}\x{061F}])\s*/u

  @typedoc "One chunk of a page's markdown, as stored in `Doctrans.Documents.Chunk`."
  @type chunk :: %{
          chunk_index: non_neg_integer(),
          content: String.t(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          word_count: non_neg_integer()
        }

  @doc """
  Splits text into chunks without overlap.

  Returns a list of maps with:
  - `:chunk_index` - 0-based position
  - `:content` - the raw chunk text (no overlap)
  - `:start_offset` - byte offset in the original text
  - `:end_offset` - byte offset end (exclusive)
  - `:word_count` - number of words in the chunk

  Use `content_for_embedding/2` to get content with overlap prepended,
  suitable for generating embeddings with surrounding context.
  """
  @spec chunk(String.t() | nil) :: [chunk()]
  def chunk(nil), do: []
  def chunk(""), do: []

  def chunk(text) do
    text = String.trim(text)

    if text == "" do
      []
    else
      paragraphs = split_paragraphs(text)
      raw_chunks = build_raw_chunks(paragraphs)
      index_chunks(raw_chunks)
    end
  end

  @doc """
  Returns chunk content with overlap from the previous chunk prepended.

  This is used for embedding generation so that each chunk has surrounding
  context, improving retrieval quality. The stored `content` field remains
  overlap-free to avoid duplication when building chat context.
  """
  @spec content_for_embedding([chunk()], non_neg_integer()) :: String.t()
  def content_for_embedding(chunks, chunk_index) when chunk_index == 0 do
    case Enum.at(chunks, 0) do
      nil -> ""
      chunk -> chunk.content
    end
  end

  def content_for_embedding(chunks, chunk_index) do
    chunk = Enum.at(chunks, chunk_index)
    prev = Enum.at(chunks, chunk_index - 1)

    if chunk && prev do
      overlap = tail_words(prev.content, @overlap_words)

      if overlap != "" do
        overlap <> "\n\n" <> chunk.content
      else
        chunk.content
      end
    else
      if chunk, do: chunk.content, else: ""
    end
  end

  # Split text into paragraphs tracking byte offsets.
  # Returns [{content, start_byte_offset, end_byte_offset}]
  defp split_paragraphs(text) do
    parts = String.split(text, ~r/\n\n+/)

    {paragraphs, _} =
      Enum.reduce(parts, {[], 0}, fn part, {acc, search_from} ->
        trimmed = String.trim(part)

        if trimmed == "" do
          {acc, search_from}
        else
          start_offset = find_offset(text, trimmed, search_from)
          end_offset = start_offset + byte_size(trimmed)
          {[{trimmed, start_offset, end_offset} | acc], end_offset}
        end
      end)

    Enum.reverse(paragraphs)
  end

  defp find_offset(text, substring, search_from) do
    scope_size = byte_size(text) - search_from

    if scope_size <= 0 do
      search_from
    else
      case :binary.match(text, substring, scope: {search_from, scope_size}) do
        {pos, _len} -> pos
        :nomatch -> search_from
      end
    end
  end

  # Pass 1: greedily group paragraphs into chunks targeting @target_words.
  # Returns [{content, start_offset, end_offset}]
  defp build_raw_chunks([]), do: []

  defp build_raw_chunks(paragraphs) do
    # current_rev accumulates paragraphs in reverse order for efficiency
    {chunks, current_rev} =
      Enum.reduce(paragraphs, {[], []}, &accumulate_paragraph/2)

    # Emit any remaining paragraphs
    all_chunks =
      if current_rev != [] do
        [finalize_paras(Enum.reverse(current_rev)) | chunks]
      else
        chunks
      end

    Enum.reverse(all_chunks)
  end

  defp accumulate_paragraph({para_text, para_start, _para_end} = para, {chunks, current}) do
    cond do
      # A paragraph over the target is split on its own, whether or not
      # anything precedes it. The old clause also required `current == []`, so
      # an introduction ahead of a long paragraph sent it down the branch
      # below, which emits a paragraph whole however large it is -- one short
      # intro turned the rest of a page into a single chunk (PLAN.md S04).
      # Whatever is accumulated is flushed first so the long paragraph starts a
      # chunk rather than joining one.
      oversized?(para_text) ->
        {Enum.reverse(split_oversized(para_text, para_start)) ++ flush(current, chunks), []}

      # Adding this paragraph would exceed target and we have content: emit current, start new
      exceeds_target?(current, para) ->
        {[finalize_paras(Enum.reverse(current)) | chunks], [para]}

      # Accumulate (prepend, reverse later)
      true ->
        {chunks, [para | current]}
    end
  end

  defp flush([], chunks), do: chunks
  defp flush(current, chunks), do: [finalize_paras(Enum.reverse(current)) | chunks]

  defp oversized?(text) do
    word_count(text) > @target_words or grapheme_count(text) > @target_graphemes
  end

  defp exceeds_target?([], _para), do: false

  defp exceeds_target?(current, {para_text, _start, _end}) do
    current_word_count(current) + word_count(para_text) > @target_words or
      current_grapheme_count(current) + grapheme_count(para_text) > @target_graphemes
  end

  # Assign indexes to raw chunks
  defp index_chunks(raw_chunks) do
    raw_chunks
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} -> to_chunk_map(raw, index) end)
  end

  defp to_chunk_map({content, start_offset, end_offset}, index) do
    %{
      chunk_index: index,
      content: content,
      start_offset: start_offset,
      end_offset: end_offset,
      word_count: word_count(content)
    }
  end

  # Get the last N words of a text (returns up to n words)
  defp tail_words(text, n) do
    words = String.split(text, ~r/\s+/, trim: true)
    words |> Enum.take(-n) |> Enum.join(" ")
  end

  defp finalize_paras(paras) do
    content = Enum.map_join(paras, "\n\n", fn {text, _, _} -> text end)
    {_, start_offset, _} = List.first(paras)
    {_, _, end_offset} = List.last(paras)
    {content, start_offset, end_offset}
  end

  defp current_word_count(paras) do
    Enum.reduce(paras, 0, fn {text, _, _}, acc -> acc + word_count(text) end)
  end

  defp current_grapheme_count(paras) do
    Enum.reduce(paras, 0, fn {text, _, _}, acc -> acc + grapheme_count(text) end)
  end

  # Split an oversized paragraph into chunks that respect the limits.
  #
  # Everything here works in byte spans into `text` rather than by joining
  # strings back together, and a chunk is always one contiguous span. That is
  # what makes `binary_part(text, start_offset, end_offset - start_offset)`
  # return the chunk's content exactly: the separators between segments are
  # inside the span, so nothing has to be reconstructed and nothing can drift.
  # The previous implementation rejoined sentences with a single space and
  # advanced the offset by the length of that join, so every chunk after the
  # first pointed at the wrong bytes (PLAN.md Q04).
  defp split_oversized(text, base_offset) do
    text
    |> segment_spans()
    |> group_spans(text, base_offset)
  end

  # The units a chunk is assembled from: sentences, and -- where one sentence
  # is itself over the hard limit -- the words or graphemes it breaks into.
  defp segment_spans(text) do
    text
    |> sentence_spans()
    |> Enum.flat_map(&bound_segment(text, &1))
  end

  # Sentences as {start, length} spans, taken as the gaps between boundary
  # matches so that the terminator stays with the sentence it ends.
  defp sentence_spans(text) do
    size = byte_size(text)

    {spans, tail_start} =
      @sentence_boundary
      |> Regex.scan(text, return: :index)
      |> Enum.map(&hd/1)
      |> Enum.reduce({[], 0}, &take_sentence/2)

    spans
    |> prepend_tail(tail_start, size)
    |> Enum.reverse()
  end

  defp take_sentence({pos, len}, {spans, from}) do
    if pos > from do
      {[{from, pos - from} | spans], pos + len}
    else
      # A zero-width or leading boundary match: advance past it without
      # emitting an empty sentence.
      {spans, max(from, pos + len)}
    end
  end

  defp prepend_tail(spans, tail_start, size) when tail_start < size do
    [{tail_start, size - tail_start} | spans]
  end

  defp prepend_tail(spans, _tail_start, _size), do: spans

  # A sentence within the hard limits is one segment. One over them is broken
  # at word boundaries, and a "word" still over them -- a run of CJK with no
  # spaces in it at all -- at grapheme boundaries. This is the hard fallback:
  # after it, no segment can exceed the limits, so no chunk can either.
  defp bound_segment(text, span) do
    if within_limits?(slice(text, span)) do
      [span]
    else
      text
      |> word_spans(span)
      |> Enum.flat_map(&bound_word(text, &1))
    end
  end

  defp bound_word(text, span) do
    if within_limits?(slice(text, span)), do: [span], else: grapheme_spans(text, span)
  end

  defp within_limits?(text) do
    word_count(text) <= @max_words and grapheme_count(text) <= @max_graphemes
  end

  # Non-whitespace runs within a span, as absolute {start, length} pairs.
  defp word_spans(text, {start, len}) do
    ~r/\S+/
    |> Regex.scan(slice(text, {start, len}), return: :index)
    |> Enum.map(fn [{pos, size}] -> {start + pos, size} end)
  end

  # A run with no whitespace to break on is cut into fixed grapheme runs. The
  # cut is by grapheme rather than by byte so it can never land inside a
  # multi-byte character and produce invalid UTF-8.
  defp grapheme_spans(text, {start, len}) do
    text
    |> slice({start, len})
    |> String.graphemes()
    |> Enum.chunk_every(@target_graphemes)
    |> Enum.map_reduce(start, fn graphemes, offset ->
      size = graphemes |> Enum.join() |> byte_size()
      {{offset, size}, offset + size}
    end)
    |> elem(0)
  end

  # Fill a chunk with segments until a budget is reached, then start the next.
  defp group_spans(spans, text, base_offset) do
    {chunks, open} = Enum.reduce(spans, {[], nil}, &take_segment(&1, &2, text))

    chunks
    |> close_open(open, text, base_offset)
    |> Enum.reverse()
  end

  defp take_segment(span, {chunks, nil}, _text), do: {chunks, span}

  defp take_segment({start, len}, {chunks, {open_start, _open_len} = open}, text) do
    combined = {open_start, start + len - open_start}

    if fits?(slice(text, combined)) do
      {chunks, combined}
    else
      {[open | chunks], {start, len}}
    end
  end

  defp fits?(text) do
    word_count(text) <= @target_words and grapheme_count(text) <= @target_graphemes
  end

  defp close_open(chunks, nil, _text, _base_offset), do: chunks

  defp close_open(chunks, open, text, base_offset) do
    [open | chunks]
    |> Enum.reverse()
    |> Enum.map(&to_span_chunk(&1, text, base_offset))
    |> Enum.reverse()
  end

  defp to_span_chunk({start, len}, text, base_offset) do
    content = slice(text, {start, len})
    {content, base_offset + start, base_offset + start + byte_size(content)}
  end

  defp slice(text, {start, len}), do: binary_part(text, start, len)

  defp word_count(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp grapheme_count(text), do: String.length(text)
end
