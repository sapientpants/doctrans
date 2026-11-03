defmodule Doctrans.Documents.Document do
  @moduledoc """
  Schema for an uploaded document being translated. The upload is a PDF or one of
  the office formats `Doctrans.Documents.Formats` converts to PDF first
  (`.doc`, `.docx`, `.odt`, `.rtf`).

  ## Statuses

  - `uploading` - the file is being stored; no run has started
  - `queued` - a run has started and its extraction job is waiting its turn

  - `extracting` - Converting to PDF where needed and extracting page images
  - `processing` - Extracting markdown and translating pages
  - `completed` - All pages have been translated
  - `error` - An error occurred during processing
  - `cancelled` - processing was stopped by the user; the document can be reprocessed

  The transitions between them, and which are legal from where, are
  `Doctrans.Documents.Lifecycle`'s; this schema only validates the column.
  """
  use Doctrans.Schema
  import Ecto.Changeset

  alias Doctrans.Languages

  @statuses ~w(uploading queued extracting processing completed error cancelled)

  schema "documents" do
    field :title, :string
    field :original_filename, :string
    field :source_extension, :string
    field :total_pages, :integer
    field :status, :string, default: "uploading"
    field :target_language, :string
    field :source_language, :string
    field :error_message, :string
    field :processing_run_id, Ecto.UUID
    field :extraction_model, :string
    field :translation_model, :string

    has_many :pages, Doctrans.Documents.Page

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      # :id is explicitly cast because the upload flow pre-generates the UUID
      # to create the upload directory before the document record exists.
      # This is safe since UUIDs are generated server-side, not from user input.
      :id,
      :title,
      :original_filename,
      :total_pages,
      :status,
      :target_language,
      :source_language,
      :error_message
    ])
    |> validate_required([:title, :original_filename, :target_language])
    |> validate_inclusion(:status, @statuses)
    # Both languages are checked here, on the update path as well as on create,
    # so a document can never hold a language the translation list does not
    # offer. A nil source language is "detect it" and passes untouched.
    |> validate_inclusion(:target_language, Languages.supported())
    |> validate_inclusion(:source_language, Languages.supported())
  end

  @doc """
  Changeset for a status transition, with the diagnostic that goes with it.

  `Doctrans.Documents.Lifecycle` is its only caller.
  """
  @spec status_changeset(t() | Ecto.Changeset.t(), String.t(), String.t() | nil) ::
          Ecto.Changeset.t()
  def status_changeset(document, status, error_message \\ nil) do
    document
    |> cast(%{status: status, error_message: error_message}, [:status, :error_message])
    |> validate_inclusion(:status, @statuses)
  end
end
