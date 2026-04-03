defmodule Doctrans.Documents.Chunk do
  @moduledoc """
  Schema for a text chunk within a page.

  Pages are split into smaller chunks (~300 words) for fine-grained
  semantic search. Each chunk gets its own embedding vector.
  """
  use Doctrans.Schema
  import Ecto.Changeset

  @statuses ~w(pending processing completed error)

  schema "chunks" do
    field :chunk_index, :integer
    field :content, :string
    field :translated_content, :string
    field :start_offset, :integer
    field :end_offset, :integer
    field :word_count, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_status, :string, default: "pending"

    belongs_to :page, Doctrans.Documents.Page

    timestamps()
  end

  @doc false
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :chunk_index,
      :content,
      :translated_content,
      :start_offset,
      :end_offset,
      :word_count
    ])
    |> validate_required([:chunk_index, :content])
  end

  @doc """
  Changeset for updating embedding results.
  """
  def embedding_changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:embedding, :embedding_status])
    |> validate_inclusion(:embedding_status, @statuses)
  end
end
