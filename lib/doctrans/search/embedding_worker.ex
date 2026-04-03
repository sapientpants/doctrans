defmodule Doctrans.Search.EmbeddingWorker do
  @moduledoc """
  Background worker for generating chunk embeddings.

  Listens for page extraction completion, splits page content into chunks,
  and generates embeddings for each chunk individually.
  """

  use GenServer
  require Logger

  use Gettext, backend: DoctransWeb.Gettext

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
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_cast({:generate, page_id}, state) do
    task =
      Task.Supervisor.async_nolink(
        Doctrans.TaskSupervisor,
        fn -> do_generate_embedding(page_id) end
      )

    tasks = Map.put(state.tasks, task.ref, page_id)
    {:noreply, %{state | tasks: tasks}}
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

    {:noreply, %{state | tasks: tasks}}
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

    {:noreply, %{state | tasks: tasks}}
  end

  defp do_generate_embedding(page_id, attempt \\ 0) do
    page = Repo.get!(Page, page_id)

    if page.extraction_status != "completed" do
      Logger.debug("Skipping embedding for page #{page_id} - extraction not completed")
      {:ok, page_id}
    else
      {:ok, page} =
        page
        |> Page.embedding_changeset(%{embedding_status: "processing"})
        |> Repo.update()

      # Create chunks from page content
      chunks = ensure_chunks(page)

      if chunks == [] do
        Logger.info("No chunks to embed for page #{page_id} (empty content)")

        page
        |> Page.embedding_changeset(%{embedding_status: "completed"})
        |> Repo.update!()

        {:ok, page_id}
      else
        # Build chunk data for overlap computation
        chunk_data = Chunker.chunk(page.original_markdown)

        # Embed each chunk (with overlap context for embedding quality)
        results =
          Enum.map(chunks, fn chunk ->
            embed_content = Chunker.content_for_embedding(chunk_data, chunk.chunk_index)
            embed_chunk(chunk, embed_content, attempt)
          end)

        if Enum.all?(results, &match?({:ok, _}, &1)) do
          # Also generate page-level embedding for hybrid search fallback
          generate_page_embedding(page)

          page
          |> Page.embedding_changeset(%{embedding_status: "completed"})
          |> Repo.update!()

          Logger.info("Generated embeddings for #{length(chunks)} chunks on page #{page_id}")
          {:ok, page_id}
        else
          failed_count = Enum.count(results, &match?({:error, _}, &1))

          Logger.error(
            "#{failed_count}/#{length(chunks)} chunk embeddings failed for page #{page_id}"
          )

          mark_embedding_error(page)
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

    Enum.map(chunk_data, fn data ->
      %Chunk{page_id: page.id}
      |> Chunk.changeset(data)
      |> Repo.insert!()
    end)
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

  @doc """
  Updates translated content on existing chunks after translation completes.
  Re-chunks the translated text and matches by chunk_index.
  """
  def update_chunk_translations(page) do
    chunks =
      Chunk
      |> where([c], c.page_id == ^page.id)
      |> order_by([c], c.chunk_index)
      |> Repo.all()

    if chunks != [] and page.translated_markdown do
      translated_chunks = Chunker.chunk(page.translated_markdown)

      Enum.each(chunks, fn chunk ->
        translated_data = Enum.find(translated_chunks, &(&1.chunk_index == chunk.chunk_index))

        if translated_data do
          chunk
          |> Chunk.changeset(%{translated_content: translated_data.content})
          |> Repo.update!()
        end
      end)
    end
  end

  defp embed_chunk(chunk, embed_content, attempt) do
    chunk =
      chunk
      |> Chunk.embedding_changeset(%{embedding_status: "processing"})
      |> Repo.update!()

    result =
      CircuitBreaker.call(:embedding_api, fn ->
        embedding_module().generate(embed_content, [])
      end)

    case result do
      {:ok, embedding} ->
        chunk
        |> Chunk.embedding_changeset(%{embedding: embedding, embedding_status: "completed"})
        |> Repo.update!()

        {:ok, chunk.id}

      {:error, :circuit_open} ->
        Logger.warning("Embedding circuit breaker open for chunk #{chunk.id}")
        mark_chunk_error(chunk)
        {:error, :circuit_open}

      {:error, reason} ->
        handle_chunk_error(chunk, embed_content, reason, attempt)
    end
  end

  defp generate_page_embedding(page) do
    result =
      CircuitBreaker.call(:embedding_api, fn ->
        embedding_module().generate(page.original_markdown, [])
      end)

    case result do
      {:ok, embedding} ->
        page
        |> Page.embedding_changeset(%{embedding: embedding})
        |> Repo.update!()

      {:error, reason} ->
        Logger.warning("Page-level embedding failed for page #{page.id}: #{inspect(reason)}")
    end
  end

  defp handle_chunk_error(chunk, embed_content, reason, attempt) do
    classification = ErrorClassifier.classify(reason)

    cond do
      classification == :permanent ->
        Logger.error("Permanent embedding error for chunk #{chunk.id}: #{inspect(reason)}")
        mark_chunk_error(chunk)
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
        embed_chunk(chunk, embed_content, attempt + 1)

      true ->
        Logger.error(
          "Embedding failed for chunk #{chunk.id} after #{@max_retries} retries: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:doctrans, :retry, :exhausted],
          %{count: 1},
          %{type: :embedding, chunk_id: chunk.id}
        )

        mark_chunk_error(chunk)
        {:error, reason}
    end
  end

  defp mark_embedding_error(page) do
    page
    |> Page.embedding_changeset(%{embedding_status: "error"})
    |> Repo.update!()
  end

  defp mark_chunk_error(chunk) do
    chunk
    |> Chunk.embedding_changeset(%{embedding_status: "error"})
    |> Repo.update!()
  end
end
