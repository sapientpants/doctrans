defmodule Doctrans.Documents.Source do
  @moduledoc """
  A Document's retained original: where it is, whether it is there, and the
  format it was stored under.

  Intake stores every accepted upload as `original.<extension>` in the
  document's own directory, and every Run starts from that file. The document
  records the extension it was stored under so the path can be rebuilt from
  the row alone -- which is what Extraction needs to find its source, Backup
  to check a restored library, Processing status to decide whether a reprocess
  can be offered, and the cleanup job to tell a converted PDF from the
  original it was made from.
  """

  alias Doctrans.Documents.{Document, Formats, Layout}
  alias Doctrans.Repo

  @doc """
  The path of the retained original, or `nil` for a document whose format the
  application does not retain.

  Older documents predate the recorded extension; theirs is read from the
  original filename instead.
  """
  @spec path(Document.t()) :: String.t() | nil
  def path(%Document{} = document) do
    extension = document.source_extension || Formats.extension(document.original_filename)

    if Formats.supported?(extension) do
      Layout.original_path(document.id, extension)
    end
  end

  @doc "Whether the retained original is a readable regular file where `path/1` says it is."
  @spec available?(Document.t()) :: boolean()
  def available?(%Document{} = document) do
    case path(document) do
      nil ->
        false

      path ->
        match?(
          {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write],
          File.stat(path)
        )
    end
  end

  @doc "Whether the retained original is already a PDF, so a Run needs no conversion first."
  @spec pdf?(Document.t()) :: boolean()
  def pdf?(%Document{} = document) do
    case path(document) do
      nil -> false
      path -> Formats.pdf?(path)
    end
  end

  @doc """
  Records the extension of the Source stored at `path` as the document's source
  format, unless the document already records one.

  `path` is the stored file, whose extension passed magic-byte validation; one
  that is not a supported source format is refused and nothing is written.
  """
  @spec record_extension(Document.t(), String.t()) ::
          {:ok, Document.t()} | {:error, {:unsupported_format, [format: String.t()]}}
  def record_extension(%Document{} = document, path) do
    extension = Formats.extension(path)

    if Formats.supported?(extension) do
      {:ok,
       document
       |> Ecto.Changeset.change(source_extension: document.source_extension || extension)
       |> Repo.update!()}
    else
      {:error, {:unsupported_format, [format: extension]}}
    end
  end
end
