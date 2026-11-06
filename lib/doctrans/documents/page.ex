defmodule Doctrans.Documents.Page do
  @moduledoc """
  Schema for a single page within a document.

  Each page goes through three stages:
  1. Extraction - the configured vision model extracts markdown from the page image
  2. Translation - the configured text model translates the markdown
  3. Embedding - the page's source text is chunked and embedded for retrieval

  ## Statuses

  `extraction_status`, `translation_status` and `embedding_status` can be:
  - `pending` - Not yet started
  - `processing` - Currently being processed
  - `completed` - Successfully completed
  - `error` - An error occurred

  None is written here. Every stage status change is a named transition of
  `Doctrans.Documents.PageLifecycle`; `changeset/2` casts neither a stage
  status nor a stage's product or model.
  """
  use Doctrans.Schema
  import Ecto.Changeset

  @statuses ~w(pending processing completed error)

  schema "pages" do
    field :page_number, :integer
    field :image_path, :string
    field :processing_generation, Ecto.UUID
    field :requested_extraction_model, :string
    field :requested_translation_model, :string
    field :extraction_model, :string
    field :translation_model, :string
    field :content_revision, :integer, default: 0, read_after_writes: true
    field :original_markdown, :string
    field :translated_markdown, :string
    field :extraction_status, :string, default: "pending"
    field :translation_status, :string, default: "pending"

    # Page-level embedding for semantic search. `Doctrans.Search.Indexer` embeds
    # `original_markdown` -- the source text, not the translation.
    field :embedding, Pgvector.Ecto.Vector, read_after_writes: true
    field :embedding_status, :string, default: "pending", read_after_writes: true

    # Note: The pages table also has tsvector columns (original_searchable,
    # translated_searchable) managed by database triggers. These are not
    # included in the schema since they're only accessed via raw SQL queries.

    belongs_to :document, Doctrans.Documents.Document
    has_many :chunks, Doctrans.Documents.Chunk

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Query-land predicate for a page whose content failed.

  A page fails when a required stage errored and translation never succeeded,
  so failure and success stay disjoint: every page is counted at most once.
  """
  defmacro failed?(page) do
    quote do
      unquote(page).translation_status != "completed" and
        (unquote(page).extraction_status == "error" or
           unquote(page).translation_status == "error")
    end
  end

  @doc """
  Query-land predicate for a page whose content has reached a terminal state.

  The union of success and `failed?/1`, expressed by delegating to it rather
  than restating it: a settled page has either finished translation or errored
  in a required stage, so nothing but reprocessing will change its contribution
  to its document's outcome.
  """
  defmacro settled?(page) do
    quote do
      unquote(page).translation_status == "completed" or
        unquote(__MODULE__).failed?(unquote(page))
    end
  end

  @doc """
  In-memory counterpart of `failed?/1` for already-loaded page statuses.

  Must express the same rule; the database and the UI would otherwise disagree
  about which pages failed.
  """
  @spec failed_status?(%{
          required(:extraction_status) => String.t(),
          required(:translation_status) => String.t(),
          optional(atom()) => term()
        }) :: boolean()
  def failed_status?(%{extraction_status: extraction, translation_status: translation}) do
    translation != "completed" and (extraction == "error" or translation == "error")
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(page, attrs) do
    page
    |> cast(attrs, [:page_number, :image_path])
    |> validate_required([:page_number])
  end

  # The one changeset that writes a stage: its status and its product -- the
  # markdown and the model for a content stage, the vector for embedding. Only
  # `Doctrans.Documents.PageLifecycle` calls it.
  @doc false
  @spec stage_changeset(t(), map()) :: Ecto.Changeset.t()
  def stage_changeset(page, attrs) do
    page
    |> cast(attrs, [
      :extraction_status,
      :translation_status,
      :embedding_status,
      :original_markdown,
      :translated_markdown,
      :extraction_model,
      :translation_model,
      :embedding
    ])
    |> validate_inclusion(:extraction_status, @statuses)
    |> validate_inclusion(:translation_status, @statuses)
    |> validate_inclusion(:embedding_status, @statuses)
  end

  # The one changeset that starts a page over: a new processing generation, no
  # content, no models, every stage pending, the requested models recorded.
  # Written with `change/2` because it sets fields no cast admits (the
  # generation, the embedding). Only `Doctrans.Documents.PageLifecycle` calls it.
  @doc false
  @spec reset_changeset(t(), map()) :: Ecto.Changeset.t()
  def reset_changeset(page, choices) do
    change(page, %{
      processing_generation: Uniq.UUID.uuid7(),
      requested_extraction_model: Map.get(choices, :extraction_model),
      requested_translation_model: Map.get(choices, :translation_model),
      extraction_model: nil,
      translation_model: nil,
      original_markdown: nil,
      translated_markdown: nil,
      extraction_status: "pending",
      translation_status: "pending",
      embedding: nil,
      embedding_status: "pending"
    })
  end
end
