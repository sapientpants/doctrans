defmodule DoctransWeb.DocumentLive.Upload do
  @moduledoc """
  Socket state for the dashboard's upload dialog and the submissions it makes.

  Owns the upload half of `DoctransWeb.DocumentLive.Index`: the upload
  configuration and its limits, the dialog's open state and language choices,
  the journey of every entry a submission carries, and what the user is told
  about each of them -- which flash, and whether the dialog stays open to carry
  the list. `Index` forwards the dialog's events here and judges nothing.

  The rules for accepting a file -- the size recheck, the magic bytes, the move
  into a generated document directory, the record and the queued job -- are
  `Doctrans.Documents.Intake`'s, where they are tested and reused without a
  socket. What is here is only what knows about the socket and
  `Phoenix.LiveView.UploadEntry`: the limits `allow_upload/3` is configured
  with, the translation of the errors LiveView reports for an entry, the
  `{:ok, _}` wrapper `consume_uploaded_entry/3` expects back, and the reporting
  rules, which are about the modal and the toast -- which of them stays open,
  which would go unseen -- and belong nowhere near the code that stores files.
  """
  use Gettext, backend: DoctransWeb.Gettext

  import Phoenix.Component, only: [assign: 3, upload_errors: 2]

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_upload: 3, consume_uploaded_entry: 3, put_flash: 3]

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents.{Formats, Intake}
  alias Doctrans.Validation
  alias DoctransWeb.DocumentLive.{DocumentStream, UploadReadiness}
  alias DoctransWeb.ErrorMessages

  @max_entries 10

  @typedoc "What became of one file in a submission."
  @type outcome ::
          {:ok, Ecto.UUID.t()}
          | {:pending, String.t()}
          | {:error, String.t(), Doctrans.Errors.reason()}

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

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

  @doc "How many files one submission may carry."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "The extensions the file picker offers: every format a document can be uploaded in."
  @spec accept() :: [String.t()]
  def accept, do: Formats.supported_extensions()

  @doc """
  Assigns the dialog's state and configures the upload.

  The source language starts on "Detect automatically", never on the configured
  language: `config :doctrans, :defaults, source_language` is no longer a
  default *choice*, it is only the fallback recorded when detection cannot
  identify the language, so starting the picker on it would put a guess in
  front of the user as though they had made it. The target picker's
  preselection is `config :doctrans, :defaults, target_language:`.
  """
  def init(socket) do
    defaults = Application.get_env(:doctrans, :defaults, [])

    socket
    |> assign(:show_upload_modal, false)
    |> clear()
    |> assign(:source_language, "")
    |> assign(:target_language, defaults[:target_language] || "en")
    |> allow_upload(:document,
      accept: accept(),
      max_entries: max_entries(),
      # The client-side limit; the on-disk size is re-verified in
      # `consume_entry/2` before the file is accepted.
      max_file_size: max_file_size()
    )
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  # The readiness check is started per open, not per mount: it costs two HTTP
  # calls, only a user about to upload needs the answer, and reopening the
  # dialog after fixing a setting is then the retry, with no control to explain.
  def handle_event("show_upload_modal", _params, socket) do
    {:noreply, socket |> assign(:show_upload_modal, true) |> clear() |> UploadReadiness.check()}
  end

  def handle_event("hide_upload_modal", _params, socket),
    do: {:noreply, assign(socket, :show_upload_modal, false)}

  def handle_event("validate_upload", params, socket) do
    socket =
      socket
      |> assign(:source_language, params["source_language"] || socket.assigns.source_language)
      |> assign(:target_language, params["target_language"] || socket.assigns.target_language)

    # Picking files again is the retry the failure list asks for, so the list of
    # what failed last time goes with the submission it described. This event also
    # fires for the language selects, which are not that retry: clearing there
    # would take the explanation away from a user who is still reading it.
    socket = if params["_target"] == ["document"], do: clear(socket), else: socket

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :document, ref)}

  def handle_event("upload_document", params, socket), do: {:noreply, submit(socket, params)}

  # ---------------------------------------------------------------------------
  # The submission
  # ---------------------------------------------------------------------------

  @doc """
  Submits every entry the dialog holds under the languages `params` carry (or
  the dialog's current choices), reports the outcomes, and refreshes the cards
  of whatever started.
  """
  @spec submit(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def submit(socket, params) do
    source_language = params["source_language"] || socket.assigns.source_language
    target_language = params["target_language"] || socket.assigns.target_language

    case Intake.validate_languages(source_language, target_language) do
      {:ok, languages} -> submit_entries(socket, languages)
      {:error, reason} -> put_flash(socket, :error, ErrorMessages.message(reason))
    end
  end

  # One pass over the entries in the order the user picked them, so the outcome list
  # reads the same way the drop zone above it does. Entries are consumed one at a
  # time rather than through `consume_uploaded_entries/3`, which takes the whole
  # config at once and raises while any entry is still pending -- that is how one
  # file the browser rejected took the outcome of every file beside it down with
  # the socket.
  defp submit_entries(socket, languages) do
    upload = socket.assigns.uploads.document

    {socket, outcomes} =
      Enum.reduce(upload.entries, {socket, []}, fn entry, {socket, acc} ->
        {socket, outcome} = process_entry(socket, upload, entry, languages)
        {socket, [outcome | acc]}
      end)

    outcomes = Enum.reverse(outcomes)

    socket |> report(outcomes) |> refresh_started(outcomes)
  end

  # The cards for what this submission started, in the same render: the
  # `{:document_created, _}` broadcast refreshes them again, unchanged, but only
  # once it arrives.
  defp refresh_started(socket, outcomes) do
    if Enum.any?(outcomes, &match?({:ok, _document_id}, &1)),
      do: DocumentStream.refresh(socket),
      else: socket
  end

  # One entry's whole journey, so that its place in the report is its place in the
  # list the user is looking at.
  defp process_entry(socket, upload, entry, languages) do
    cond do
      not entry.valid? ->
        # Cancelled so it stops blocking the config it sits in; its reason travels
        # in the outcome list instead.
        {cancel_upload(socket, :document, entry.ref),
         {:error, entry.client_name, entry_reason(upload_errors(upload, entry), entry)}}

      not entry.done? ->
        # Still on its way. Left in the modal for the submission that finishes it,
        # and reported so it is never silently dropped from a submission that
        # otherwise succeeded.
        {socket, {:pending, entry.client_name}}

      true ->
        {socket, start_entry(socket, entry, languages)}
    end
  end

  defp start_entry(socket, entry, languages) do
    consumed =
      consume_uploaded_entry(socket, entry, fn meta ->
        # `meta` is an opaque map from LiveView; coerce the path to a string
        # so the type stays concrete for downstream File calls.
        path = to_string(Map.get(meta, :path, ""))
        consume_entry(path, entry)
      end)

    if Intake.accepted?(consumed),
      do: Intake.create_and_process(consumed, languages),
      else: consumed
  end

  @doc """
  Hands one consumed upload to `Intake.accept/2`.

  Returns `{:ok, result}` because LiveView unwraps the outer `:ok` for each
  consumed entry, leaving an `Intake.result/0` per file -- a rejected file is a
  result, not a failure of the consume.
  """
  @spec consume_entry(Path.t(), Phoenix.LiveView.UploadEntry.t()) :: {:ok, Intake.result()}
  def consume_entry(path, entry), do: {:ok, Intake.accept(path, entry.client_name)}

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

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  @doc "Reports one submission's outcomes on the socket."
  @spec report(Phoenix.LiveView.Socket.t(), [outcome()]) :: Phoenix.LiveView.Socket.t()
  def report(socket, []) do
    socket |> clear() |> put_flash(:error, gettext("No files were uploaded"))
  end

  def report(socket, outcomes) do
    started = Enum.count(outcomes, &match?({:ok, _document_id}, &1))
    failures = Enum.filter(outcomes, &match?({:error, _filename, _reason}, &1))
    pending = for {:pending, filename} <- outcomes, do: filename

    socket
    |> report_started(started)
    |> report_outcomes(failures, pending, started)
  end

  @doc "Drops the outcomes of the previous submission."
  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket) do
    socket
    |> assign(:upload_failures, [])
    |> assign(:upload_pending, [])
    |> assign(:upload_started, 0)
  end

  @doc """
  The message for documents a submission queued for processing.

  Shared with the modal's own outcome list, so the dashboard flash and the list
  cannot drift apart.
  """
  @spec started_message(non_neg_integer()) :: String.t()
  def started_message(count) do
    ngettext(
      "Document uploaded! Processing will begin shortly.",
      "%{count} documents uploaded! Processing will begin shortly.",
      count
    )
  end

  # No flash for the nothing-started case: it only happens alongside failures, which
  # keep the modal open, and the modal's backdrop covers the toast (z-999 against
  # z-50) until it dismisses itself unseen. The failure list says it instead.
  defp report_started(socket, 0), do: socket
  defp report_started(socket, count), do: put_flash(socket, :info, started_message(count))

  # The modal closes only when there is nothing left to say. Anything else keeps it
  # open to carry the list: a rejected file needs its reason next to the drop zone
  # it goes back into, and a file still uploading needs to stay visible.
  defp report_outcomes(socket, [], [], _started) do
    socket |> assign(:show_upload_modal, false) |> clear()
  end

  defp report_outcomes(socket, failures, pending, started) do
    socket
    |> assign(:upload_failures, Enum.map(failures, &describe_failure/1))
    |> assign(:upload_pending, pending)
    |> assign(:upload_started, started)
  end

  # The name is displayed, so it is the sanitized one rather than whatever the
  # browser sent, matching the title the accepted files are stored under.
  defp describe_failure({:error, filename, reason}) do
    %{name: Validation.sanitize_filename_string(filename), message: ErrorMessages.message(reason)}
  end
end
