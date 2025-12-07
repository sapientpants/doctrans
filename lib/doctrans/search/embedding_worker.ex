defmodule Doctrans.Search.EmbeddingWorker do
  @moduledoc """
  Background worker for generating page embeddings.

  Listens for page translation completion and generates embeddings
  for the translated content.
  """

  use GenServer
  require Logger

  alias Doctrans.Documents.Page
  alias Doctrans.Repo

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
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:generate, page_id}, state) do
    Task.Supervisor.async_nolink(
      Doctrans.TaskSupervisor,
      fn -> do_generate_embedding(page_id) end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp do_generate_embedding(page_id) do
    page = Repo.get!(Page, page_id)

    # Only generate embedding if extraction is completed
    if page.extraction_status != "completed" do
      Logger.debug("Skipping embedding for page #{page_id} - extraction not completed")
      :ok
    else
      # Update status to processing
      {:ok, page} =
        page
        |> Page.embedding_changeset(%{embedding_status: "processing"})
        |> Repo.update()

      # Use original markdown for embedding - it's language-agnostic
      case embedding_module().generate(page.original_markdown, []) do
        {:ok, embedding} ->
          page
          |> Page.embedding_changeset(%{
            embedding: embedding,
            embedding_status: "completed"
          })
          |> Repo.update!()

          Logger.info("Generated embedding for page #{page_id}")

        {:error, reason} ->
          Logger.error("Failed to generate embedding for page #{page_id}: #{reason}")

          page
          |> Page.embedding_changeset(%{embedding_status: "error"})
          |> Repo.update!()
      end
    end
  end
end
