defmodule Doctrans.Documents.Intake do
  @moduledoc """
  Takes a file into the library: verifies it, stores it, records it, queues it.

  An upload arrives as a path on disk and the name the client gave it. `accept/2`
  re-reads the size, checks the magic bytes against the claimed extension and
  moves the file into a directory of its own under a generated document id.
  `create_and_process/2` then inserts the document record and queues extraction,
  undoing whichever of those two steps completed when the other fails.

  Nothing here knows about sockets, upload entries or flash messages. The web layer
  (`DoctransWeb.DocumentLive.UploadIntake`) adapts a LiveView entry to these two
  calls and renders their outcomes; any other caller -- a mix task, a test fixture,
  an API -- gets the same rules by calling them directly.
  """

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Layout}
  alias Doctrans.Errors
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Validation

  require Logger

  @typedoc "A file that passed validation and now has a directory of its own on disk."
  @type accepted ::
          {:ok, document_id :: Ecto.UUID.t(), filename :: String.t(), path :: String.t()}

  @typedoc "The outcome of `accept/2`: the stored file, or the name it failed under and why."
  @type result :: accepted() | {:error, filename :: String.t(), reason :: Errors.reason()}

  @typedoc """
  The direction one submission translates in, as two validated language codes.

  A `nil` source is "Detect automatically": nothing was chosen, and the language is
  identified during processing instead.
  """
  @type languages :: %{source: String.t() | nil, target: String.t()}

  @typedoc """
  The outcome of `create_and_process/2`: the document now queued for processing, or
  the file it failed on and why.
  """
  @type start_result ::
          {:ok, document_id :: Ecto.UUID.t()}
          | {:error, filename :: String.t(), reason :: Errors.reason()}

  @doc """
  Validates a file and moves it into its own document directory.

  `client_name` is the name the file arrived under; its extension decides which
  magic bytes the content must carry, and the name itself travels into the result
  so a rejection can be reported against the file the user recognises. The stored
  copy is always `original.<extension>`, with the extension lowercased, inside a
  directory named after a freshly generated id -- nothing derived from the client
  name reaches the filesystem.

  A rejected file is a result, not a failure: a caller handling several files at
  once reports each on its own.
  """
  @spec accept(Path.t(), String.t()) :: result()
  # Source: a temp path the caller owns. Destination: generated UUID + "original" +
  # magic-byte-validated extension.
  # sobelow_skip ["Traversal.FileModule"]
  def accept(path, client_name) do
    # Normalized once: `File` takes any `Path.t()`, but `Validation.validate_file_content/2`
    # guards on a binary, and a charlist path would be rejected as invalid arguments
    # rather than checked.
    path = to_string(path)
    extension = client_name |> Path.extname() |> String.downcase()

    with :ok <- validate_disk_size(path, Uploads.max_file_size()),
         :ok <- Validation.validate_file_content(path, extension),
         {:ok, document_id, dest_path} <- store(path, extension) do
      {:ok, document_id, client_name, dest_path}
    else
      {:error, reason} ->
        Logger.warning("Upload rejected for #{client_name}: #{inspect(reason)}")
        {:error, client_name, reason}
    end
  end

  @doc """
  Whether an `accept/2` result is a stored file.
  """
  @spec accepted?(result()) :: boolean()
  def accepted?({:ok, _document_id, _filename, _path}), do: true
  def accepted?({:error, _filename, _reason}), do: false

  @doc """
  Validates the pair of language codes one submission was made with.

  A blank source -- `nil`, or a string with nothing in it but whitespace -- is
  "Detect automatically" rather than a mistake, and validates to a `nil` source:
  processing identifies the language itself. The target has nothing to detect
  and is still required.

  Check both before accepting any file: a language the user has to fix is theirs
  to fix with the files still in hand, and reporting it after the files were
  stored would leave documents behind for a submission that never started.
  """
  @spec validate_languages(term(), term()) :: {:ok, languages()} | {:error, Errors.reason()}
  def validate_languages(source_language, target_language) do
    with {:ok, source} <- validate_source(source_language),
         {:ok, target} <- Validation.validate_language(target_language) do
      {:ok, %{source: source, target: target}}
    end
  end

  # The picker's "Detect automatically" posts the empty string, and a caller with
  # no value at all hands over `nil`; both mean the same absence of a choice, and
  # both validate to a `nil` source. The trim only decides whether there is a
  # choice in there at all -- a real code goes to `Validation` as it arrived,
  # which normalizes it itself.
  defp validate_source(nil), do: {:ok, nil}

  defp validate_source(source) when is_binary(source) do
    if String.trim(source) == "" do
      {:ok, nil}
    else
      Validation.validate_language(source)
    end
  end

  defp validate_source(source), do: Validation.validate_language(source)

  @doc """
  Creates the document record for an `accept/2` result and queues it for processing.

  Returns `{:ok, document_id}` only once the extraction job is queued, so a file
  reported as uploaded is one that processing will actually pick up. Either failure
  takes the upload directory with it, and a document whose job could not be queued
  is deleted rather than left sitting in `uploading` forever with no job that will
  ever move it.

  `document_id` must be one `accept/2` generated. Cleanup deletes the row it
  inserted under that id, so handing this a persisted id would delete that document
  and its files.
  """
  @spec create_and_process(accepted(), languages()) :: start_result()
  def create_and_process({:ok, document_id, original_filename, source_path}, languages) do
    # Sanitized in the head of the function that carries the rescue: a rebinding
    # inside a `try` body is not visible to its `rescue`, so sanitizing in there
    # would leave the raise path reporting and logging the raw client filename.
    start_upload(
      document_id,
      Validation.sanitize_filename_string(original_filename),
      source_path,
      languages
    )
  end

  # The insert raises rather than returns when the database is unreachable, and a
  # raise here would take the caller down along with the outcome of every other
  # file in the same submission. `catch` covers the exits too -- a pool checkout
  # timeout or a `:noproc` from a Repo that is not up exits rather than raises.
  #
  # Only the directory is cleaned up: the insert did not complete, so there is no
  # row this call can claim, and deleting whatever happens to sit at that id is how
  # a caller's own document would get destroyed.
  defp start_upload(document_id, filename, source_path, languages) do
    attrs = %{
      id: document_id,
      title: title_from(filename),
      original_filename: filename,
      # `nil` when the submission left the picker on "Detect automatically": the
      # column is nullable, and processing resolves the language before it runs.
      source_language: languages.source,
      target_language: languages.target,
      status: "uploading"
    }

    case create_document(attrs, filename) do
      {:ok, document} -> start_processing(document, source_path, filename)
      {:error, _filename, _reason} = error -> error
    end
  rescue
    exception ->
      abandon(document_id, filename, Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, reason ->
      abandon(document_id, filename, inspect({kind, reason}))
  end

  # Past the insert the row is this call's own, so cleanup may delete it. The outage
  # that caused the raise can equally block the delete; what cannot be removed is
  # left to the sweeper rather than to a second raise.
  defp start_processing(document, source_path, filename) do
    case enqueue(document, source_path, filename) do
      :ok -> {:ok, document.id}
      {:error, _filename, _reason} = error -> error
    end
  rescue
    exception ->
      abandon(document, filename, Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, reason ->
      abandon(document, filename, inspect({kind, reason}))
  end

  defp abandon(%Document{} = document, filename, formatted) do
    Logger.error("Upload of #{filename} failed: #{formatted}")
    _ = safely(fn -> delete_document(document) end, document.id)
    {:error, filename, :upload_start_failed}
  end

  defp abandon(document_id, filename, formatted) do
    Logger.error("Upload of #{filename} failed: #{formatted}")
    _ = safely(fn -> discard_upload(document_id) end, document_id)
    {:error, filename, :upload_start_failed}
  end

  defp safely(cleanup, document_id) do
    cleanup.()
  catch
    kind, reason ->
      Logger.error("Could not clean up #{document_id}: #{inspect({kind, reason})}")
      :error
  end

  defp create_document(attrs, original_filename) do
    case Documents.create_document(attrs) do
      {:ok, document} ->
        {:ok, document}

      {:error, reason} ->
        Logger.error("Failed to create document for #{original_filename}: #{inspect(reason)}")
        _ = discard_upload(attrs.id)
        {:error, original_filename, reason}
    end
  end

  defp enqueue(document, source_path, original_filename) do
    case DocumentExtractionJob.enqueue_document(document.id, source_path) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to queue #{original_filename} for processing: #{inspect(reason)}")
        _ = delete_document(document)
        {:error, original_filename, reason}
    end
  end

  # `Documents.delete_document/1` takes the upload directory with it. A delete that
  # fails would leave a row the dashboard shows as `uploading` beside a report
  # saying the file was not uploaded, and nothing re-queues that status, so the row
  # is marked `error` instead of being left to contradict the report next to it.
  defp delete_document(document) do
    case Documents.delete_document(document) do
      {:ok, _document} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not delete document #{document.id}: #{inspect(reason)}")
        # A stable atom, not `reason`: `update_document_status/3` inspects whatever
        # it is given into a text column, and a changeset reason would persist the
        # whole document struct there.
        _ = Documents.update_document_status(document, "error", :delete_failed)
        :ok
    end
  end

  # Moving the file into its document directory is the one step here that touches
  # a disk that can be full or read-only. It returns a reason like every other step
  # rather than raising: a raise would take the caller down, and with it the other
  # files in the same submission.
  # Source: a temp path the caller owns. Destination: generated UUID + validated extension.
  # sobelow_skip ["Traversal.FileModule"]
  defp store(path, extension) do
    document_id = Uniq.UUID.uuid7()
    dest_dir = Layout.document_dir(document_id)
    dest_path = Layout.original_path(document_id, extension)

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

  # The document directory is the one `accept/2` generated from a fresh UUID, never
  # a path derived from the display filename.
  # sobelow_skip ["Traversal.FileModule"]
  defp discard_upload(document_id) do
    document_id |> Layout.document_dir() |> File.rm_rf()
  end

  # `Path.rootname/1` drops whatever extension the file carries -- `.docx` and
  # `.odt` as readily as `.pdf` -- where stripping a literal ".pdf" left every other
  # accepted format titled after its extension.
  defp title_from(original_filename) do
    original_filename
    |> Path.rootname()
    |> String.replace(~r/[_-]+/, " ")
  end

  # The client-side size limit is not a security boundary; verify the actual size
  # of the file on disk before accepting it.
  @spec validate_disk_size(String.t(), pos_integer()) :: :ok | {:error, Errors.reason()}
  defp validate_disk_size(path, max_size) do
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
