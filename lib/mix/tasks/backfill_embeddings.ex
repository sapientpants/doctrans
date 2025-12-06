defmodule Mix.Tasks.BackfillEmbeddings do
  @moduledoc """
  Generates embeddings for existing pages that don't have them yet.

  ## Usage

      mix backfill_embeddings

  This task will find all pages that have completed extraction but
  no embedding, and generate embeddings for them.
  """
  use Mix.Task
  require Logger

  import Ecto.Query
  alias Doctrans.Repo
  alias Doctrans.Documents.Page
  alias Doctrans.Search.Embedding

  @shortdoc "Generates embeddings for existing pages"

  @impl Mix.Task
  def run(_args) do
    # Start the application
    Mix.Task.run("app.start")

    Logger.info("Starting embedding backfill...")

    # Find pages that need embeddings
    pages =
      Page
      |> where([p], p.extraction_status == "completed")
      |> where([p], is_nil(p.embedding))
      |> where([p], not is_nil(p.original_markdown))
      |> Repo.all()

    total = length(pages)
    Logger.info("Found #{total} pages needing embeddings")

    pages
    |> Enum.with_index(1)
    |> Enum.each(fn {page, index} ->
      Logger.info("Processing page #{index}/#{total} (ID: #{page.id})")

      case Embedding.generate(page.original_markdown) do
        {:ok, embedding} ->
          page
          |> Page.embedding_changeset(%{
            embedding: embedding,
            embedding_status: "completed"
          })
          |> Repo.update!()

          Logger.info("  -> Embedding generated successfully")

        {:error, reason} ->
          Logger.error("  -> Failed to generate embedding: #{reason}")

          page
          |> Page.embedding_changeset(%{embedding_status: "error"})
          |> Repo.update!()
      end
    end)

    Logger.info("Embedding backfill complete!")
  end
end
