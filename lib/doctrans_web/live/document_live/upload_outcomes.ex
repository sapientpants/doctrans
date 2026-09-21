defmodule DoctransWeb.DocumentLive.UploadOutcomes do
  @moduledoc """
  Turns the per-file outcomes of one upload submission into dashboard state.

  `UploadIntake` decides what happened to each file; this decides what the user
  is told about it. The two are separate because the reporting rules are about
  the modal and the toast -- which of them stays open, which of them would go
  unseen -- and none of that belongs in the code that stores files.
  """
  use Gettext, backend: DoctransWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Doctrans.Validation
  alias DoctransWeb.DocumentLive.DocumentStream
  alias DoctransWeb.DocumentLive.UploadComponents
  alias DoctransWeb.ErrorMessages

  @typedoc "What became of one file in a submission."
  @type outcome ::
          {:ok, Ecto.UUID.t()}
          | {:pending, String.t()}
          | {:error, String.t(), Doctrans.Errors.reason()}

  @doc """
  Reports one submission's outcomes on the socket.
  """
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

  @doc """
  Drops the outcomes of the previous submission.
  """
  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket) do
    socket
    |> assign(:upload_failures, [])
    |> assign(:upload_pending, [])
    |> assign(:upload_started, 0)
  end

  # No flash for the nothing-started case: it only happens alongside failures, which
  # keep the modal open, and the modal's backdrop covers the toast (z-999 against
  # z-50) until it dismisses itself unseen. The failure list says it instead.
  defp report_started(socket, 0), do: socket

  defp report_started(socket, count) do
    socket
    |> put_flash(:info, UploadComponents.upload_started_message(count))
    |> DocumentStream.refresh()
  end

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
