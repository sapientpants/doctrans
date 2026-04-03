defmodule Doctrans.Search.Chunker do
  @moduledoc """
  Splits markdown text into overlapping chunks for fine-grained embedding.

  Respects paragraph boundaries (double newlines). Targets ~300 words per
  chunk with ~50-word overlap between consecutive chunks. Single paragraphs
  that exceed the target are split at sentence boundaries.
  """

  # Target ~300 words per chunk for fine-grained retrieval while
  # preserving enough context for meaningful embeddings.
  @target_words 300
  @overlap_words 50

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

  defp accumulate_paragraph({para_text, para_start, para_end}, {chunks, current}) do
    para_words = word_count(para_text)

    cond do
      # Long paragraph on its own: split at sentences
      para_words > @target_words and current == [] ->
        sentence_chunks = split_long_paragraph(para_text, para_start)
        {sentence_chunks ++ chunks, []}

      # Adding this paragraph would exceed target and we have content: emit current, start new
      current != [] and current_word_count(current) + para_words > @target_words ->
        chunk = finalize_paras(Enum.reverse(current))
        {[chunk | chunks], [{para_text, para_start, para_end}]}

      # Accumulate (prepend, reverse later)
      true ->
        {chunks, [{para_text, para_start, para_end} | current]}
    end
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

  # Split a long paragraph at sentence boundaries into chunks
  defp split_long_paragraph(text, base_offset) do
    sentences = split_sentences(text)

    {chunks, current_sentences, _current_words, current_offset} =
      Enum.reduce(sentences, {[], [], 0, base_offset}, fn sentence,
                                                          {completed, current, current_words,
                                                           offset} ->
        sentence_words = word_count(sentence)
        new_words = current_words + sentence_words

        if new_words >= @target_words and current != [] do
          chunk_text = Enum.join(Enum.reverse(current), " ")
          chunk = {chunk_text, offset, offset + byte_size(chunk_text)}
          next_offset = offset + byte_size(chunk_text)
          {[chunk | completed], [sentence], sentence_words, next_offset}
        else
          {completed, [sentence | current], new_words, offset}
        end
      end)

    all_chunks =
      if current_sentences != [] do
        chunk_text = Enum.join(Enum.reverse(current_sentences), " ")
        chunk = {chunk_text, current_offset, current_offset + byte_size(chunk_text)}
        [chunk | chunks]
      else
        chunks
      end

    Enum.reverse(all_chunks)
  end

  defp split_sentences(text) do
    String.split(text, ~r/(?<=[.!?])\s+(?=[A-Z])/)
  end

  defp word_count(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end
end
