defmodule Doctrans.Jobs.EmbeddingGenerationJob do
  @moduledoc """
  Job for generating embeddings for processed pages.
  This job creates vector embeddings for semantic search
  after page content has been extracted and translated.
  """

  use Oban.Worker, queue: :embedding_generation, max_attempts: 3

  alias Doctrans.Documents
  alias Doctrans.Search.Embedding

  @impl true
  def perform(%Oban.Job{args: %{"page_id" => page_id}}) do
    case Documents.get_page(page_id) do
      nil ->
        {:error, "Page not found"}

      page ->
        # Generate embedding for translated content if available, otherwise original
        content = page.translated_markdown || page.original_markdown

        if content do
          Embedding.generate(content)
        else
          {:error, "No content available for embedding generation"}
        end
    end
  end
end
