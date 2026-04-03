defmodule Mix.Tasks.RechunkDocuments do
  @moduledoc """
  Re-chunks and re-embeds all existing document pages.

  This task is used after adding sub-page chunking support to process
  documents that were originally embedded at the page level.

  Processes pages sequentially to avoid overwhelming Ollama.

  ## Usage

      mix rechunk_documents
  """

  use Mix.Task

  import Ecto.Query

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Repo
  alias Doctrans.Search.{Chunker, Embedding}

  @shortdoc "Re-chunk and re-embed all existing document pages"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    page_ids =
      Page
      |> where([p], p.extraction_status == "completed")
      |> where([p], not is_nil(p.original_markdown))
      |> select([p], p.id)
      |> Repo.all()

    total = length(page_ids)
    Mix.shell().info("Found #{total} pages to re-chunk and re-embed")

    {success, errors} =
      page_ids
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {page_id, index}, {ok, err} ->
        Mix.shell().info("Processing page #{index}/#{total}: #{page_id}")

        case process_page(page_id) do
          :ok ->
            {ok + 1, err}

          {:error, reason} ->
            Mix.shell().error("  Failed: #{inspect(reason)}")
            {ok, err + 1}
        end
      end)

    Mix.shell().info("Done. #{success} succeeded, #{errors} failed.")
  end

  defp process_page(page_id) do
    page = Repo.get!(Page, page_id)

    # Delete existing chunks
    Chunk |> where([c], c.page_id == ^page_id) |> Repo.delete_all()

    # Create new chunks
    chunk_data = Chunker.chunk(page.original_markdown)

    if chunk_data == [] do
      Mix.shell().info("  No chunks (empty content), skipping")
      :ok
    else
      chunks = insert_chunks(page, chunk_data)
      update_translations(page, chunks)
      results = embed_chunks(chunks)
      embed_page(page)

      failed = Enum.count(results, &match?({:error, _}, &1))
      Mix.shell().info("  #{length(chunks)} chunks, #{failed} failed")

      if failed > 0, do: {:error, :some_chunks_failed}, else: :ok
    end
  end

  defp insert_chunks(page, chunk_data) do
    Enum.map(chunk_data, fn data ->
      %Chunk{page_id: page.id}
      |> Chunk.changeset(data)
      |> Repo.insert!()
    end)
  end

  defp update_translations(page, chunks) do
    if page.translated_markdown do
      translated_data = Chunker.chunk(page.translated_markdown)

      Enum.each(chunks, fn chunk ->
        match = Enum.find(translated_data, &(&1.chunk_index == chunk.chunk_index))

        if match do
          chunk |> Chunk.changeset(%{translated_content: match.content}) |> Repo.update!()
        end
      end)
    end
  end

  defp embed_chunks(chunks) do
    # Compute chunk data for overlap context, matching production embedding behavior
    chunk_data =
      Enum.map(chunks, fn c -> %{chunk_index: c.chunk_index, content: c.content} end)

    Enum.map(chunks, fn chunk ->
      embed_content = Chunker.content_for_embedding(chunk_data, chunk.chunk_index)

      case embedding_module().generate(embed_content, []) do
        {:ok, embedding} ->
          chunk
          |> Chunk.embedding_changeset(%{embedding: embedding, embedding_status: "completed"})
          |> Repo.update!()

          :ok

        {:error, reason} ->
          chunk |> Chunk.embedding_changeset(%{embedding_status: "error"}) |> Repo.update!()
          {:error, reason}
      end
    end)
  end

  defp embed_page(page) do
    case embedding_module().generate(page.original_markdown, []) do
      {:ok, embedding} ->
        page
        |> Page.embedding_changeset(%{embedding: embedding, embedding_status: "completed"})
        |> Repo.update!()

      {:error, _} ->
        :ok
    end
  end

  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Embedding)
  end
end
