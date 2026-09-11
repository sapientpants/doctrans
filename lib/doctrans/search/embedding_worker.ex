defmodule Doctrans.Search.EmbeddingWorker do
  @moduledoc """
  Background worker for generating chunk embeddings.

  Listens for page extraction completion, splits page content into chunks,
  and generates embeddings for each chunk individually.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Repo
  alias Doctrans.Resilience.{Backoff, CircuitBreaker, ErrorClassifier}
  alias Doctrans.Search.Chunker

  import Ecto.Query

  @max_retries 3

  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queue a page for chunk creation and embedding generation.
  """
  def generate_embedding(page_id) do
    GenServer.cast(__MODULE__, {:generate, page_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{tasks: %{}, pending: MapSet.new()}}
  end

  @impl true
  def handle_cast({:generate, page_id}, state) do
    if page_id in Map.values(state.tasks) do
      {:noreply, %{state | pending: MapSet.put(state.pending, page_id)}}
    else
      task =
        Task.Supervisor.async_nolink(
          Doctrans.TaskSupervisor,
          fn -> do_generate_embedding(page_id) end
        )

      tasks = Map.put(state.tasks, task.ref, page_id)
      {:noreply, %{state | tasks: tasks}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])
    {page_id, tasks} = Map.pop(state.tasks, ref)

    case result do
      {:ok, _page_id} ->
        Logger.debug("Embedding task completed for page #{page_id}")

      {:error, reason} ->
        Logger.warning("Embedding task failed for page #{page_id}: #{inspect(reason)}")

      _ ->
        :ok
    end

    finish_task(page_id, %{state | tasks: tasks})
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {page_id, tasks} = Map.pop(state.tasks, ref)

    if page_id do
      Logger.error("Embedding task crashed for page #{page_id}: #{inspect(reason)}")

      :telemetry.execute(
        [:doctrans, :embedding, :crashed],
        %{count: 1},
        %{page_id: page_id, reason: inspect(reason)}
      )
    else
      Logger.error("Unknown embedding task crashed: #{inspect(reason)}")
    end

    finish_task(page_id, %{state | tasks: tasks})
  end

  defp finish_task(page_id, state) do
    if MapSet.member?(state.pending, page_id) do
      handle_cast({:generate, page_id}, %{state | pending: MapSet.delete(state.pending, page_id)})
    else
      {:noreply, state}
    end
  end

  defp do_generate_embedding(page_id, attempt \\ 0) do
    page = Repo.get(Page, page_id)

    cond do
      page == nil ->
        Logger.debug("Embedding requested for deleted page #{page_id}; skipping")
        {:ok, page_id}

      page.extraction_status != "completed" ->
        Logger.debug("Skipping embedding for page #{page_id} - extraction not completed")
        {:ok, page_id}

      true ->
        process_page_embedding(page, page_id, attempt)
    end
  end

  defp process_page_embedding(page, page_id, attempt) do
    case safe_update!(Page.embedding_changeset(page, %{embedding_status: "processing"}), page) do
      {:error, _} ->
        Logger.debug("Page #{page_id} was deleted before embedding; skipping")
        {:ok, page_id}

      {:ok, page} ->
        # Create chunks from page content
        chunks =
          case with_current_revision(page, &ensure_chunks/1) do
            {:ok, chunks} -> chunks
            {:error, :stale_entry} -> []
          end

        if chunks == [] do
          Logger.info("No chunks to embed for page #{page_id} (empty content)")

          _ = safe_update!(Page.embedding_changeset(page, %{embedding_status: "completed"}), page)

          {:ok, page_id}
        else
          # Build chunk data for overlap computation
          chunk_data = Chunker.chunk(page.original_markdown)

          # Embed each chunk (with overlap context for embedding quality)
          results =
            Enum.map(chunks, fn chunk ->
              embed_content = Chunker.content_for_embedding(chunk_data, chunk.chunk_index)
              embed_chunk(chunk, embed_content, attempt, page)
            end)

          if Enum.all?(results, &match?({:ok, _}, &1)) do
            # Also generate page-level embedding for hybrid search fallback
            _ = generate_page_embedding(page)

            _ =
              safe_update!(Page.embedding_changeset(page, %{embedding_status: "completed"}), page)

            Logger.info("Generated embeddings for #{length(chunks)} chunks on page #{page_id}")
            {:ok, page_id}
          else
            failed_count = Enum.count(results, &match?({:error, _}, &1))

            Logger.error(
              "#{failed_count}/#{length(chunks)} chunk embeddings failed for page #{page_id}"
            )

            _ = mark_embedding_error(page)
            {:error, :chunk_embedding_failed}
          end
        end
    end
  end

  defp ensure_chunks(page) do
    existing =
      Chunk
      |> where([c], c.page_id == ^page.id)
      |> order_by([c], c.chunk_index)
      |> Repo.all()

    cond do
      existing == [] ->
        create_chunks(page)

      chunks_match_page_content?(existing, page.original_markdown) ->
        existing

      true ->
        recreate_chunks(page.id)
    end
  end

  defp chunks_match_page_content?(existing_chunks, original_markdown) do
    current_chunk_data =
      original_markdown
      |> Chunker.chunk()
      |> Enum.map(fn data ->
        %{chunk_index: data.chunk_index, content: data.content}
      end)

    existing_chunk_data =
      Enum.map(existing_chunks, fn chunk ->
        %{chunk_index: chunk.chunk_index, content: chunk.content}
      end)

    current_chunk_data == existing_chunk_data
  end

  defp create_chunks(page) do
    chunk_data = Chunker.chunk(page.original_markdown)

    # Source and translation boundaries are not aligned. Store source chunks only.
    Enum.each(chunk_data, fn data ->
      %Chunk{page_id: page.id}
      |> Chunk.changeset(data)
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:page_id, :chunk_index]
      )
    end)

    # Re-fetch to get actual records (on_conflict: :nothing may return empty struct)
    Chunk
    |> where([c], c.page_id == ^page.id)
    |> order_by([c], c.chunk_index)
    |> Repo.all()
  end

  @doc """
  Recreates chunks for a page, deleting any existing ones.
  Used when page content changes (e.g., re-extraction).
  """
  def recreate_chunks(page_id) do
    Chunk |> where([c], c.page_id == ^page_id) |> Repo.delete_all()
    page = Repo.get!(Page, page_id)
    create_chunks(page)
  end

  defp embed_chunk(chunk, embed_content, attempt, page) do
    case safe_update!(Chunk.embedding_changeset(chunk, %{embedding_status: "processing"}), page) do
      {:error, :stale_entry} ->
        Logger.debug("Chunk #{chunk.id} was deleted before embedding; skipping")
        {:ok, chunk.id}

      {:ok, chunk} ->
        result =
          CircuitBreaker.call(:embedding_api, fn ->
            embedding_module().generate(embed_content, [])
          end)

        case result do
          {:ok, embedding} ->
            _ =
              safe_update!(
                Chunk.embedding_changeset(chunk, %{
                  embedding: embedding,
                  embedding_status: "completed"
                }),
                page
              )

            {:ok, chunk.id}

          {:error, :circuit_open} ->
            Logger.warning("Embedding circuit breaker open for chunk #{chunk.id}")
            _ = mark_chunk_error(chunk, page)
            {:error, :circuit_open}

          {:error, reason} ->
            handle_chunk_error(chunk, embed_content, reason, attempt, page)
        end
    end
  end

  defp generate_page_embedding(page) do
    result =
      CircuitBreaker.call(:embedding_api, fn ->
        embedding_module().generate(page.original_markdown, [])
      end)

    case result do
      {:ok, embedding} ->
        _ = safe_update!(Page.embedding_changeset(page, %{embedding: embedding}), page)

      {:error, reason} ->
        Logger.warning("Page-level embedding failed for page #{page.id}: #{inspect(reason)}")
    end
  end

  defp handle_chunk_error(chunk, embed_content, reason, attempt, page) do
    classification = ErrorClassifier.classify(reason)

    cond do
      classification == :permanent ->
        Logger.error("Permanent embedding error for chunk #{chunk.id}: #{inspect(reason)}")
        _ = mark_chunk_error(chunk, page)
        {:error, reason}

      attempt < @max_retries ->
        delay = Backoff.calculate(attempt, base: 1_000, max: 10_000)

        Logger.warning(
          "Embedding failed for chunk #{chunk.id}, retrying in #{delay}ms (#{attempt + 1}/#{@max_retries})"
        )

        :telemetry.execute(
          [:doctrans, :retry, :attempt],
          %{count: 1, delay_ms: delay},
          %{type: :embedding, chunk_id: chunk.id, attempt: attempt + 1}
        )

        Process.sleep(delay)
        embed_chunk(chunk, embed_content, attempt + 1, page)

      true ->
        Logger.error(
          "Embedding failed for chunk #{chunk.id} after #{@max_retries} retries: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:doctrans, :retry, :exhausted],
          %{count: 1},
          %{type: :embedding, chunk_id: chunk.id}
        )

        _ = mark_chunk_error(chunk, page)
        {:error, reason}
    end
  end

  defp mark_embedding_error(page) do
    safe_update!(Page.embedding_changeset(page, %{embedding_status: "error"}), page)
  end

  defp mark_chunk_error(chunk, page) do
    safe_update!(Chunk.embedding_changeset(chunk, %{embedding_status: "error"}), page)
  end

  # `Repo.update!` raises `Ecto.StaleEntryError` when the row is deleted while
  # the task is in flight (e.g. the user removes the book mid-embedding). The
  # row is gone, so there is nothing to update — treat it as a no-op.
  defp safe_update!(changeset, page) do
    with_current_revision(page, fn _current -> Repo.update!(changeset) end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Serialize writes with content invalidation, without holding a lock during API calls.
  defp with_current_revision(page, fun) do
    Repo.transaction(fn ->
      current = Repo.one(from p in Page, where: p.id == ^page.id, lock: "FOR UPDATE")

      if current && current.content_revision == page.content_revision &&
           current.extraction_status == "completed" do
        fun.(current)
      else
        Repo.rollback(:stale_entry)
      end
    end)
  end
end
