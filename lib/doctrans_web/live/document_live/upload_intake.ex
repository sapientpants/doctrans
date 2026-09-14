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

  @typedoc "An entry that passed validation and now has a file of its own on disk."
  @type accepted ::
          {:ok, document_id :: Ecto.UUID.t(), filename :: String.t(), path :: String.t()}

  @type upload_result ::
          accepted()
          | {:error, filename :: String.t(), reason :: Doctrans.Errors.reason()}

  @typedoc """
  The outcome of starting one accepted upload: the document that is now queued for
  processing, or the file it failed on and why.
  """
  @type start_result ::
          {:ok, document_id :: Ecto.UUID.t()}
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
         :ok <- Validation.validate_file_content(path, extension),
         {:ok, document_id, dest_path} <- store(path, extension) do
      {:ok, {:ok, document_id, entry.client_name, dest_path}}
    else
      {:error, reason} ->
        Logger.warning("Upload rejected for #{entry.client_name}: #{inspect(reason)}")
        {:ok, {:error, entry.client_name, reason}}
    end
  end

  # Moving the file into its document directory is the one step here that touches
  # a disk that can be full or read-only. It returns a reason like every other step
  # rather than raising: a raise inside `consume_uploaded_entries/3` takes the
  # dashboard down with it, and the other files in the same submission with it.
  # Source: LiveView temp metadata. Destination: generated UUID + validated extension.
  # sobelow_skip ["Traversal.FileModule"]
  defp store(path, extension) do
    document_id = Uniq.UUID.uuid7()
    dest_dir = Documents.document_upload_dir(document_id)
    dest_path = Path.join(dest_dir, "original#{extension}")

    with :ok <- File.mkdir_p(dest_dir),
         :ok <- File.cp(path, dest_path) do
      {:ok, document_id, dest_path}
    else
      {:error, posix} ->
        Logger.error("Could not store upload at #{dest_path}: #{inspect(posix)}")
        _ = File.rm_rf(dest_dir)
        {:error, :upload_store_failed}
    end
  end

  @doc """
  Whether a consumed entry was accepted.
  """
  @spec accepted?(upload_result()) :: boolean()
  def accepted?({:ok, _document_id, _filename, _path}), do: true
  def accepted?({:error, _filename, _reason}), do: false

  @doc """
  Creates the document record for an accepted `consume_entry/2` result and queues it
  for processing.

  Returns `{:ok, document_id}` only once the extraction job is queued, so a file the
  dashboard reports as uploaded is one that processing will actually pick up. Either
  failure takes the upload directory with it, and a document whose job could not be
  queued is deleted rather than left sitting in `uploading` forever with no job that
  will ever move it.
  """
  @spec create_and_process(accepted(), String.t()) :: start_result()
  def create_and_process({:ok, document_id, original_filename, pdf_path}, target_language) do
    original_filename = Validation.sanitize_filename_string(original_filename)

    attrs = %{
      id: document_id,
      title: title_from(original_filename),
      original_filename: original_filename,
      target_language: target_language,
      status: "uploading"
    }

    with {:ok, document} <- create_document(attrs, original_filename),
         :ok <- enqueue(document, pdf_path, original_filename) do
      {:ok, document.id}
    end
  rescue
    exception ->
      Logger.error(
        "Upload of #{original_filename} failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      _ = abandon(document_id)
      {:error, original_filename, :upload_start_failed}
  end

  # The insert and the enqueue both raise rather than return when the database is
  # unreachable, and a raise here would take the dashboard down along with the
  # outcome of every other file in the same submission. Cleanup is attempted in the
  # same breath, but the outage that caused the raise can equally block the delete:
  # what cannot be removed is left to the sweeper rather than to a second raise.
  defp abandon(document_id) do
    case Documents.get_document(document_id) do
      nil -> discard_upload(document_id)
      document -> delete_document(document)
    end
  catch
    kind, reason ->
      Logger.error("Could not clean up #{document_id}: #{inspect({kind, reason})}")
      discard_upload(document_id)
  end

  defp create_document(attrs, original_filename) do
    case Documents.create_document(attrs) do
      {:ok, document} ->
        Logger.debug("Dashboard now tracking new document:#{document.id}")
        _ = Documents.Topics.subscribe_document(document.id)
        {:ok, document}

      {:error, reason} ->
        Logger.error("Failed to create document for #{original_filename}: #{inspect(reason)}")
        _ = discard_upload(attrs.id)
        {:error, original_filename, reason}
    end
  end

  defp enqueue(document, pdf_path, original_filename) do
    case Worker.process_document(document.id, pdf_path) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to queue #{original_filename} for processing: #{inspect(reason)}")
        _ = Documents.Topics.unsubscribe_document(document.id)
        delete_document(document)
        {:error, original_filename, reason}
    end
  end

  # `Documents.delete_document/1` takes the upload directory with it. A delete that
  # fails would leave a row the dashboard shows as `uploading` beside a modal saying
  # the file was not uploaded, and nothing re-queues that status, so the row is
  # marked `error` instead of being left to contradict the report next to it.
  defp delete_document(document) do
    case Documents.delete_document(document) do
      {:ok, _document} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not delete document #{document.id}: #{inspect(reason)}")
        _ = Documents.update_document_status(document, "error", reason)
        :ok
    end
  end

  # The document directory is the one `consume_entry/2` generated from a fresh UUID,
  # never a path derived from the display filename.
  # sobelow_skip ["Traversal.FileModule"]
  defp discard_upload(document_id) do
    document_id |> Documents.document_upload_dir() |> File.rm_rf()
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
