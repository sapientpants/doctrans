defmodule Doctrans.Documents.Summary do
  @moduledoc """
  Dashboard summary with a document, calculated progress, and first-page thumbnail.

  The document remains an unmodified schema struct. Lightweight page rows are used
  during construction and are not retained in the summary. The top-level `id`
  identifies the summary in LiveView streams.
  """

  alias Doctrans.Documents.{Document, Page, Progress}

  @enforce_keys [:id, :document, :progress, :failed_pages, :thumbnail_path]
  defstruct [:id, :document, :progress, :failed_pages, :thumbnail_path]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          document: Document.t(),
          progress: float(),
          failed_pages: [integer()],
          thumbnail_path: String.t() | nil
        }

  @doc "Builds a summary from a document and its already-loaded lightweight pages."
  @spec new(Document.t(), [map()]) :: t()
  def new(%Document{} = document, pages) when is_list(pages) do
    first_page = Enum.find(pages, &(&1.page_number == 1))

    %__MODULE__{
      id: document.id,
      document: document,
      progress: Progress.calculate(pages, document.total_pages),
      # Lets the card name the pages to reprocess instead of guessing from progress.
      failed_pages: pages |> Enum.filter(&Page.failed_status?/1) |> Enum.map(& &1.page_number),
      thumbnail_path: first_page && first_page.image_path
    }
  end
end
