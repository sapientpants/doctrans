defmodule DoctransWeb.DocumentLive.UploadIntake do
  @moduledoc """
  Adapts a LiveView upload entry to `Doctrans.Documents.Intake`.

  The rules for accepting a file -- the size recheck, the magic bytes, the move
  into a generated document directory, the record and the queued job -- live in
  the `Intake` context, where they can be tested and reused without a socket. What
  is left here is only what knows about `Phoenix.LiveView.UploadEntry`: the limits
  `allow_upload/3` is configured with, the translation of the errors LiveView
  reports for an entry, and the `{:ok, _}` wrapper `consume_uploaded_entry/3`
  expects back. The context calls the dashboard makes around those are forwarded
  unchanged, so the LiveView has one module to talk to for an upload.
  """

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents.Intake

  @max_entries 10

  @doc """
  The largest upload accepted, in bytes.

  `allow_upload`'s `:max_file_size` enforces this in the browser, which is a
  convenience rather than a boundary; `Intake.accept/2` re-reads it for the real check.
  """
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: Uploads.max_file_size()

  @doc """
  The largest upload accepted, in whole megabytes.

  Rounded up, so the figure a rejection reports is never equal to the limit it
  says the file exceeded.
  """
  @spec max_file_size_mb() :: pos_integer()
  def max_file_size_mb, do: ceil(max_file_size() / 1_000_000)

  @doc """
  How many files one submission may carry.
  """
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  Translates the errors LiveView reports for an entry into the reasons the rest of
  the upload path speaks.

  A file the browser rejects and one the server rejects are described to the user
  by the same `DoctransWeb.ErrorMessages` clause, so the two halves of the modal
  cannot drift into separate vocabularies.
  """
  @spec entry_reason([atom()], Phoenix.LiveView.UploadEntry.t()) :: Doctrans.Errors.reason()
  def entry_reason([:too_large | _], entry) do
    {:file_too_large, [size: ceil(entry.client_size / 1_000_000), max: max_file_size_mb()]}
  end

  def entry_reason([:not_accepted | _], entry) do
    # A file with no extension is exactly what trips `:not_accepted`, and naming
    # the empty extension reads as a dangling colon, so it falls back to the
    # message that lists what is accepted instead.
    case Path.extname(entry.client_name) do
      "" -> :unsupported_format
      extension -> {:unsupported_format, [format: extension]}
    end
  end

  # Anything else the client reports gets the upload path's own fallback rather
  # than being spelled out here, where it would go stale against LiveView.
  def entry_reason([_other | _], _entry), do: :upload_failed
  def entry_reason([], _entry), do: :upload_unreadable

  @doc """
  Hands one consumed upload to `Intake.accept/2`.

  Returns `{:ok, result}` because LiveView unwraps the outer `:ok` for each
  consumed entry, leaving an `Intake.result/0` per file -- a rejected file is a
  result, not a failure of the consume.
  """
  @spec consume_entry(Path.t(), Phoenix.LiveView.UploadEntry.t()) :: {:ok, Intake.result()}
  def consume_entry(path, entry) do
    {:ok, Intake.accept(path, entry.client_name)}
  end

  @doc "See `Doctrans.Documents.Intake.accepted?/1`."
  defdelegate accepted?(result), to: Intake

  @doc "See `Doctrans.Documents.Intake.validate_languages/2`."
  defdelegate validate_languages(source_language, target_language), to: Intake

  @doc "See `Doctrans.Documents.Intake.create_and_process/2`."
  defdelegate create_and_process(accepted, languages), to: Intake
end
