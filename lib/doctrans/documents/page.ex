defmodule Doctrans.Documents.Page do
  @moduledoc """
  Schema for a single page within a document.

  Each page goes through two processing stages:
  1. Extraction - Using Qwen3-VL to extract markdown from the page image
  2. Translation - Using Qwen3 to translate the markdown

  ## Statuses

  Both `extraction_status` and `translation_status` can be:
  - `pending` - Not yet started
  - `processing` - Currently being processed
  - `completed` - Successfully completed
  - `error` - An error occurred
  """
  use Doctrans.Schema
  import Ecto.Changeset

  @statuses ~w(pending processing completed error)

  schema "pages" do
    field :page_number, :integer
    field :image_path, :string
    field :original_markdown, :string
    field :translated_markdown, :string
    field :extraction_status, :string, default: "pending"
    field :translation_status, :string, default: "pending"

    belongs_to :document, Doctrans.Documents.Document

    timestamps()
  end

  @doc false
  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :page_number,
      :image_path,
      :original_markdown,
      :translated_markdown,
      :extraction_status,
      :translation_status
    ])
    |> validate_required([:page_number])
    |> validate_inclusion(:extraction_status, @statuses)
    |> validate_inclusion(:translation_status, @statuses)
  end

  @doc """
  Changeset for updating extraction results.
  """
  def extraction_changeset(page, attrs) do
    page
    |> cast(attrs, [:original_markdown, :extraction_status])
    |> validate_inclusion(:extraction_status, @statuses)
  end

  @doc """
  Changeset for updating translation results.
  """
  def translation_changeset(page, attrs) do
    page
    |> cast(attrs, [:translated_markdown, :translation_status])
    |> validate_inclusion(:translation_status, @statuses)
  end
end
