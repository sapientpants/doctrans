defmodule Doctrans.Documents.Summary do
  @moduledoc """
  Dashboard summary with a document, calculated progress, and first-page thumbnail.

  The document remains an unmodified schema struct. Lightweight page rows are used
  during construction and are not retained in the summary. The top-level `id`
  identifies the summary in LiveView streams.
  """

  alias Doctrans.Documents.{Document, Progress}

  @enforce_keys [:id, :document, :progress, :thumbnail_path]
  defstruct [:id, :document, :progress, :thumbnail_path]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          document: Document.t(),
          progress: float(),
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
      thumbnail_path: first_page && first_page.image_path
    }
  end
end
