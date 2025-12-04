defmodule Doctrans.Documents.Book do
  @moduledoc """
  Schema for a book (uploaded PDF) being translated.

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

  schema "books" do
    field :title, :string
    field :original_filename, :string
    field :total_pages, :integer
    field :status, :string, default: "uploading"
    field :source_language, :string
    field :target_language, :string
    field :error_message, :string

    has_many :pages, Doctrans.Documents.Page

    timestamps()
  end

  @doc false
  def changeset(book, attrs) do
    book
    |> cast(attrs, [
      :title,
      :original_filename,
      :total_pages,
      :status,
      :source_language,
      :target_language,
      :error_message
    ])
    |> validate_required([:title, :original_filename, :source_language, :target_language])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset for updating book status.
  """
  def status_changeset(book, status, error_message \\ nil) do
    book
    |> cast(%{status: status, error_message: error_message}, [:status, :error_message])
    |> validate_inclusion(:status, @statuses)
  end
end
