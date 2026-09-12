defmodule DoctransWeb.DocumentLive.UploadIntake do
  @moduledoc """
  Turns a consumed LiveView upload into a persisted document and a queued job.

  Owns the upload half of `DoctransWeb.DocumentLive.Index`: re-verifying the file on
  disk, checking its magic bytes against its extension, moving it into the document's
  own directory under a generated id, and creating the record that the processing
  worker then picks up.

  Nothing here touches the socket — the LiveView keeps `consume_uploaded_entries/3`
  and the resulting flash messages. That boundary is the point: the size and content
  checks in here are the only thing standing between an arbitrary browser upload and
  the filesystem, and they are easier to read, and to test, away from the dashboard's
  assigns.
  """

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents
  alias Doctrans.Processing.Worker
  alias Doctrans.Validation

  require Logger

  @type upload_result ::
          {:ok, document_id :: Ecto.UUID.t(), filename :: String.t(), path :: String.t()}
          | {:error, filename :: String.t(), reason :: Doctrans.Errors.reason()}

  @doc """
  The largest upload accepted, in bytes.

  `allow_upload`'s `:max_file_size` enforces this in the browser, which is a
  convenience rather than a boundary; `consume_entry/2` re-reads it for the real check.
  """
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: Uploads.max_file_size()

  @doc """
  Validates one consumed upload and moves it into its document directory.

  Returns `{:ok, upload_result}` because LiveView unwraps the outer `:ok` for each
  consumed entry, leaving an `upload_result` per file — a rejected file is a result,
  not a failure of the consume.
  """
  @spec consume_entry(binary(), Phoenix.LiveView.UploadEntry.t()) :: {:ok, upload_result()}
  # Source: LiveView temp metadata. Destination: generated UUID + original + magic-byte-validated extension.
  # sobelow_skip ["Traversal.FileModule"]
  def consume_entry(path, entry) do
    extension = entry.client_name |> Path.extname() |> String.downcase()

    with :ok <- validate_disk_size(path, max_file_size()),
         :ok <- Validation.validate_file_content(path, extension) do
      document_id = Uniq.UUID.uuid7()
      dest_dir = Documents.document_upload_dir(document_id)
      File.mkdir_p!(dest_dir)

      dest_path = Path.join(dest_dir, "original#{extension}")
      File.cp!(path, dest_path)
      {:ok, {:ok, document_id, entry.client_name, dest_path}}
    else
      {:error, reason} ->
        Logger.warning("Upload rejected for #{entry.client_name}: #{inspect(reason)}")
        {:ok, {:error, entry.client_name, reason}}
    end
  end

  @doc """
  Whether a consumed entry was accepted.
  """
  @spec accepted?(upload_result()) :: boolean()
  def accepted?({:ok, _document_id, _filename, _path}), do: true
  def accepted?({:error, _filename, _reason}), do: false

  @doc """
  Creates the document record for an accepted upload and queues it for processing.

  The file is removed if the record cannot be created, so a failed insert does not
  leave an orphaned upload directory behind.
  """
  # The cleanup path comes from consume_entry/2, never from the display filename.
  # sobelow_skip ["Traversal.FileModule"]
  def create_and_process({document_id, original_filename, pdf_path}, target_language) do
    original_filename = Validation.sanitize_filename_string(original_filename)

    attrs = %{
      id: document_id,
      title: title_from(original_filename),
      original_filename: original_filename,
      target_language: target_language,
      status: "uploading"
    }

    case Documents.create_document(attrs) do
      {:ok, document} ->
        Logger.debug("Dashboard now tracking new document:#{document.id}")
        _ = Documents.Topics.subscribe_document(document.id)
        _ = Worker.process_document(document.id, pdf_path)

      {:error, changeset} ->
        Logger.error("Failed to create document: #{inspect(changeset)}")
        File.rm(pdf_path)
    end
  end

  defp title_from(original_filename) do
    original_filename
    |> Path.basename(".pdf")
    |> String.replace(~r/[_-]+/, " ")
  end

  # The client-side allow_upload size limit is not a security boundary;
  # verify the actual size of the file on disk before accepting it.
  @spec validate_disk_size(binary(), pos_integer()) :: :ok | {:error, Doctrans.Errors.reason()}
  defp validate_disk_size(path, max_size) do
    path = to_string(path)

    case File.stat(path) do
      {:ok, %{size: size}} when size <= max_size ->
        :ok

      {:ok, %{size: size}} ->
        {:error, {:file_too_large, [size: div(size, 1_000_000), max: div(max_size, 1_000_000)]}}

      {:error, _} ->
        {:error, :upload_unreadable}
    end
  end
end
