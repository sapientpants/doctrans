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
  Splits text into chunks with overlap.

  Returns a list of maps with:
  - `:chunk_index` - 0-based position
  - `:content` - the chunk text
  - `:start_offset` - character offset in the original text
  - `:end_offset` - character offset end (exclusive)
  - `:word_count` - number of words in the chunk
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
      add_overlap_and_index(raw_chunks)
    end
  end

  # Split text into paragraphs tracking character offsets.
  # Returns [{content, start_offset, end_offset}]
  defp split_paragraphs(text) do
    parts = String.split(text, ~r/\n\n+/)

    {paragraphs, _} =
      Enum.reduce(parts, {[], 0}, fn part, {acc, search_from} ->
        trimmed = String.trim(part)

        if trimmed == "" do
          {acc, search_from}
        else
          start_offset = find_offset(text, trimmed, search_from)
          end_offset = start_offset + String.length(trimmed)
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

  # Pass 2: add overlap between consecutive chunks and assign indexes
  defp add_overlap_and_index([]), do: []
  defp add_overlap_and_index([single]), do: [to_chunk_map(single, 0)]

  defp add_overlap_and_index(raw_chunks) do
    raw_chunks
    |> Enum.with_index()
    |> Enum.map(fn {{content, start_offset, end_offset}, index} ->
      content_with_overlap =
        if index > 0 do
          {prev_content, _, _} = Enum.at(raw_chunks, index - 1)
          overlap = tail_words(prev_content, @overlap_words)

          if overlap != "" do
            overlap <> "\n\n" <> content
          else
            content
          end
        else
          content
        end

      %{
        chunk_index: index,
        content: content_with_overlap,
        start_offset: start_offset,
        end_offset: end_offset,
        word_count: word_count(content_with_overlap)
      }
    end)
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

  # Get the last N words of a text
  defp tail_words(text, n) do
    words = String.split(text, ~r/\s+/, trim: true)

    if length(words) <= n do
      ""
    else
      words |> Enum.take(-n) |> Enum.join(" ")
    end
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

    {chunks, current_sentences, _current_words} =
      Enum.reduce(sentences, {[], [], 0}, fn sentence, {completed, current, current_words} ->
        sentence_words = word_count(sentence)
        new_words = current_words + sentence_words

        if new_words >= @target_words and current != [] do
          chunk_text = Enum.join(Enum.reverse(current), " ")
          chunk = {chunk_text, base_offset, base_offset + String.length(chunk_text)}
          {[chunk | completed], [sentence], sentence_words}
        else
          {completed, [sentence | current], new_words}
        end
      end)

    all_chunks =
      if current_sentences != [] do
        chunk_text = Enum.join(Enum.reverse(current_sentences), " ")
        chunk = {chunk_text, base_offset, base_offset + String.length(chunk_text)}
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
