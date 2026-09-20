defmodule Doctrans.Search.Chunker do
  @moduledoc """
  Splits markdown text into chunks for fine-grained embedding.

  Respects paragraph boundaries (double newlines) and fills a chunk to ~300
  words before starting the next. A paragraph over the target is split at
  sentence boundaries, a sentence still over it at word boundaries, and a word
  still over it at grapheme boundaries, so no chunk exceeds 400 words, 3,200
  graphemes or 12,800 bytes whatever the source looks like.

  Stored chunk content carries no overlap. `content_for_embedding/2` prepends a
  bounded tail of the previous chunk so an embedding still sees its context.

  Grouping paragraphs is this module's job; `Doctrans.Search.Chunker.Segments`
  owns the budgets themselves and the splitting of a paragraph too large to be
  one chunk.
  """

  # Embedding overlap, bounded in every unit for the reason the chunk itself is:
  # the word tail alone returns the whole of a Japanese chunk, because it sees
  # one word -- a 2,394-grapheme chunk went to the embedding server as 4,794.
  @overlap_words 50
  @overlap_graphemes 400
  @overlap_bytes 1600

  alias Doctrans.Search.Chunker.Segments

  @typedoc "One chunk of a page's markdown, as stored in `Doctrans.Documents.Chunk`."
  @type chunk :: %{
          chunk_index: non_neg_integer(),
          content: String.t(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          word_count: non_neg_integer()
        }

  # A chunk before it is indexed: {content, start_offset, end_offset}.
  @typep raw_chunk :: {String.t(), non_neg_integer(), non_neg_integer()}

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
    # `Regex.scan/3` on a Unicode pattern raises `ArgumentError` on invalid
    # UTF-8, and `Segments` splits with one. An oversized paragraph holding a
    # stray byte would otherwise take the raise
    # through `Indexer`, whose Oban job retries it deterministically and leaves
    # the page's `embedding_status` at "processing" for good. Postgres rejects
    # these bytes in a text column, so this is a guard rather than a path with a
    # known caller; offsets are into the sanitized text when it fires.
    text = if String.valid?(text), do: text, else: String.replace_invalid(text)
    trimmed = String.trim(text)

    if trimmed == "" do
      []
    else
      # Offsets are built against the trimmed text, so the whitespace trimmed
      # off the front is added back to every one of them -- otherwise they are
      # offsets into a string the caller never passed in.
      base = byte_size(text) - byte_size(String.trim_leading(text))

      trimmed
      |> split_paragraphs()
      |> build_raw_chunks(trimmed)
      |> index_chunks(base)
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
      overlap = overlap_tail(prev.content)

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
  #
  # `include_captures` keeps the separators in the list, so a part's position is
  # the sum of the byte sizes before it and every offset is arithmetic rather
  # than searched for. Searching the text for each paragraph needed a fallback
  # for a miss that could not happen, and an offset out of range is no longer a
  # pointer that merely reads back wrong: `finalize_paras/2` slices the text
  # with it, and a length past the end raises `ArgumentError`, which `Indexer`'s
  # Oban job retries deterministically -- leaving the page's `embedding_status`
  # at "processing" for good. This way there is nothing to guard.
  defp split_paragraphs(text) do
    text
    |> String.split(~r/\n\n+/, include_captures: true)
    |> Enum.reduce({[], 0}, &take_paragraph/2)
    |> elem(0)
    |> Enum.reverse()
  end

  # Separators trim to "" and only advance the offset, so they need no clause of
  # their own.
  defp take_paragraph(part, {paragraphs, offset}) do
    next_offset = offset + byte_size(part)
    trimmed = String.trim(part)

    if trimmed == "" do
      {paragraphs, next_offset}
    else
      start_offset = next_offset - byte_size(String.trim_leading(part))
      {[{trimmed, start_offset, start_offset + byte_size(trimmed)} | paragraphs], next_offset}
    end
  end

  # Pass 1: greedily group paragraphs into chunks, up to the fill target
  # `Segments` defines. Returns [raw_chunk()]
  defp build_raw_chunks([], _text), do: []

  defp build_raw_chunks(paragraphs, text) do
    # current_rev accumulates paragraphs in reverse order for efficiency, and
    # `measure` is what the span from the first of them to the last comes to.
    {chunks, current_rev, _measure} =
      Enum.reduce(paragraphs, {[], [], Segments.zero()}, &accumulate_paragraph(&1, &2, text))

    chunks
    |> flush_paragraphs(current_rev, text)
    |> Enum.reverse()
  end

  defp accumulate_paragraph(
         {para_text, para_start, _end} = para,
         {_chunks, current_rev, acc} = state,
         text
       ) do
    para_measure = Segments.measure(para_text)
    extended = extend(acc, para_measure, current_rev, para_start, text)

    cond do
      not Segments.within?(para_measure, :target) -> split_paragraph(para, state, text)
      Segments.within?(extended, :target) -> keep_paragraph(para, extended, state)
      true -> start_chunk(para, para_measure, state, text)
    end
  end

  # A paragraph over the target is split on its own, whether or not anything
  # precedes it (PLAN.md S04). Whatever is accumulated is flushed first, so the
  # long paragraph starts a chunk rather than joining one.
  defp split_paragraph({para_text, para_start, _end}, {chunks, current_rev, _acc}, text) do
    split = Enum.reverse(Segments.split(para_text, para_start))
    {split ++ flush_paragraphs(chunks, current_rev, text), [], Segments.zero()}
  end

  # Adding this paragraph would pass the target and we have content: emit what
  # is accumulated, start the next chunk with this paragraph.
  defp start_chunk(para, para_measure, {chunks, current_rev, _acc}, text) do
    {flush_paragraphs(chunks, current_rev, text), [para], para_measure}
  end

  # Accumulate (prepend, reverse later).
  defp keep_paragraph(para, extended, {chunks, current_rev, _acc}) do
    {chunks, [para | current_rev], extended}
  end

  defp flush_paragraphs(chunks, [], _text), do: chunks

  defp flush_paragraphs(chunks, current_rev, text),
    do: [finalize_paras(Enum.reverse(current_rev), text) | chunks]

  # What the accumulated paragraphs would measure with this one appended. The
  # chunk is the span from the first paragraph's start to this one's end, so the
  # gap between the two -- whatever the source actually holds there, not the two
  # bytes an earlier version assumed -- is inside the span and has to be
  # counted.
  #
  # The gap is measured the same way a paragraph is, which keeps the running
  # total an upper bound on the span's own measure: concatenation can merge two
  # tokens, or two grapheme clusters, into one, but it can never produce a
  # third, so a sum of parts overshoots and never undershoots. An upper bound is
  # what the ceilings rest on. Counting the gap as zero words instead would
  # undershoot wherever it holds whitespace `word_count/1` does not recognise --
  # non-breaking or ideographic spacer lines, which an HTML-to-markdown
  # conversion leaves behind -- and 500 of those between two paragraphs made one
  # 501-word chunk out of a ceiling of 400.
  defp extend(_measure, para_measure, [], _para_start, _text), do: para_measure

  defp extend(measure, para_measure, [{_, _, prev_end} | _], para_start, text) do
    gap = binary_part(text, prev_end, para_start - prev_end)

    measure
    |> Segments.add(Segments.measure(gap))
    |> Segments.add(para_measure)
  end

  # A chunk is one contiguous byte span, here as in `Segments`: its content is
  # the source between the first paragraph's start and the last one's end, blank
  # lines and all, rather than the paragraphs rejoined on a separator the source
  # may never have had. That is what makes
  # `binary_part(text, start_offset, end_offset - start_offset)` return the
  # content exactly (PLAN.md Q04).
  defp finalize_paras(paras, text) do
    {_, start_offset, _} = List.first(paras)
    {_, _, end_offset} = List.last(paras)
    {binary_part(text, start_offset, end_offset - start_offset), start_offset, end_offset}
  end

  # Assign indexes to raw chunks, shifting offsets back onto the original text.
  @spec index_chunks([raw_chunk()], non_neg_integer()) :: [chunk()]
  defp index_chunks(raw_chunks, base) do
    raw_chunks
    |> Enum.with_index()
    |> Enum.map(fn {{content, start_offset, end_offset}, index} ->
      %{
        chunk_index: index,
        content: content,
        start_offset: base + start_offset,
        end_offset: base + end_offset,
        word_count: Segments.word_count(content)
      }
    end)
  end

  # The tail of the previous chunk, prepended to this one for embedding. Bounded
  # in graphemes and bytes as well as words, because the word tail is the whole
  # chunk for any script that does not space-separate.
  #
  # `include_captures` keeps the separators, so the tail is a byte suffix of the
  # chunk it came from rather than its words rebuilt on a separator the source
  # may never have had -- the same principle `finalize_paras/2` applies to a
  # chunk's own content (PLAN.md Q04, Q05). Joining on a literal `" "` flattened
  # every newline, tab and run of spaces inside the tail: `"a\nb"` was embedded
  # as `"a b"`, so what the embedding server saw was not text that appears
  # anywhere in the page.
  #
  # With the separators kept, the parts alternate word, separator, word -- chunk
  # content is trimmed at both ends, so neither end is a separator -- and 50
  # words are the last `2 * 50 - 1` parts: the words plus the 49 separators
  # between them. The grapheme and byte bound below trims only from the front of
  # that, which leaves it a suffix.
  defp overlap_tail(text) do
    text
    |> String.split(~r/\s+/, trim: true, include_captures: true)
    |> Enum.take(-(2 * @overlap_words - 1))
    |> Enum.join()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0, 0}, fn grapheme, {acc, count, size} ->
      size = size + byte_size(grapheme)

      if count + 1 > @overlap_graphemes or size > @overlap_bytes do
        {:halt, {acc, count, size}}
      else
        {:cont, {[grapheme | acc], count + 1, size}}
      end
    end)
    |> elem(0)
    |> Enum.join()
  end
end
