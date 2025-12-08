defmodule Doctrans.Search.EmbeddingWorker do
  @moduledoc """
  Background worker for generating page embeddings.

  Listens for page translation completion and generates embeddings
  for the translated content.
  """

  use GenServer
  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Documents.Page
  alias Doctrans.Repo
  alias Doctrans.Resilience.{Backoff, CircuitBreaker, ErrorClassifier}

  @max_retries 3

  # Allow embedding module to be configured for testing
  defp embedding_module do
    Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queue a page for embedding generation.
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

    # Track task with page_id for better error reporting
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

    # Only generate embedding if extraction is completed
    if page.extraction_status != "completed" do
      Logger.debug("Skipping embedding for page #{page_id} - extraction not completed")
      {:ok, page_id}
    else
      # Update status to processing
      {:ok, page} =
        page
        |> Page.embedding_changeset(%{embedding_status: "processing"})
        |> Repo.update()

      # Use circuit breaker for embedding API calls
      result =
        CircuitBreaker.call(:embedding_api, fn ->
          embedding_module().generate(page.original_markdown, [])
        end)

      case result do
        {:ok, embedding} ->
          page
          |> Page.embedding_changeset(%{
            embedding: embedding,
            embedding_status: "completed"
          })
          |> Repo.update!()

          Logger.info("Generated embedding for page #{page_id}")
          {:ok, page_id}

        {:error, :circuit_open} ->
          Logger.warning("Embedding circuit breaker open for page #{page_id}")
          mark_embedding_error(page)
          {:error, :circuit_open}

        {:error, reason} ->
          handle_embedding_error(page, reason, attempt)
      end
    end
  end

  defp handle_embedding_error(page, reason, attempt) do
    classification = ErrorClassifier.classify(reason)

    cond do
      # Permanent error - don't retry
      classification == :permanent ->
        Logger.error("Permanent embedding error for page #{page.id}: #{inspect(reason)}")
        mark_embedding_error(page)
        {:error, reason}

      # Retryable error and we have retries left
      attempt < @max_retries ->
        delay = Backoff.calculate(attempt, base: 1_000, max: 10_000)

        Logger.warning(
          "Embedding failed for page #{page.id}, retrying in #{delay}ms (#{attempt + 1}/#{@max_retries})"
        )

        :telemetry.execute(
          [:doctrans, :retry, :attempt],
          %{count: 1, delay_ms: delay},
          %{type: :embedding, page_id: page.id, attempt: attempt + 1}
        )

        Process.sleep(delay)
        do_generate_embedding(page.id, attempt + 1)

      # Max retries exceeded
      true ->
        Logger.error(
          "Embedding failed for page #{page.id} after #{@max_retries} retries: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:doctrans, :retry, :exhausted],
          %{count: 1},
          %{type: :embedding, page_id: page.id}
        )

        mark_embedding_error(page)
        {:error, reason}
    end
  end

  defp mark_embedding_error(page) do
    page
    |> Page.embedding_changeset(%{embedding_status: "error"})
    |> Repo.update!()
  end
end
