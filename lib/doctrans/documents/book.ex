defmodule Doctrans.Documents.Document do
  @moduledoc """
  Schema for a document (uploaded PDF) being translated.

  ## Statuses

  - `uploading` - PDF is being uploaded
  - `extracting` - Extracting page images from PDF
  - `processing` - Extracting markdown and translating pages
  - `completed` - All pages have been translated
  - `error` - An error occurred during processing
  """
  use Doctrans.Schema
  import Ecto.Changeset

  @statuses ~w(uploading extracting processing completed error)

  schema "documents" do
    field :title, :string
    field :original_filename, :string
    field :total_pages, :integer
    field :status, :string, default: "uploading"
    field :target_language, :string
    field :error_message, :string

    has_many :pages, Doctrans.Documents.Page

    timestamps()
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :title,
      :original_filename,
      :total_pages,
      :status,
      :target_language,
      :error_message
    ])
    |> validate_required([:title, :original_filename, :target_language])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset for updating document status.
  """
  def status_changeset(document, status, error_message \\ nil) do
    document
    |> cast(%{status: status, error_message: error_message}, [:status, :error_message])
    |> validate_inclusion(:status, @statuses)
  end
end
