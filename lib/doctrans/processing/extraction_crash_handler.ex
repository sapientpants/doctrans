defmodule Doctrans.Processing.ExtractionCrashHandler do
  @moduledoc """
  Fails the document of an extraction job that ended without reaching
  `Doctrans.Processing.Extraction`'s own failure path.

  `Extraction.run/2` records every failure it returns through
  `Doctrans.Documents.Lifecycle.fail/2`, so the document reads `error` as soon
  as its job does. A job that is killed instead never returns there: Oban's own
  timeout exits the job process, and a raise or an exit inside the run unwinds
  past the record. Such a job leaves the document `extracting` with no job
  behind it once its attempts run out, and until this handler existed
  `Doctrans.Processing.StartupRecovery` re-queued that document on every boot.

  This handler listens to Oban's `[:oban, :job, :exception]` event for
  `Doctrans.Jobs.DocumentExtractionJob` and makes the transition the run could
  not, under the same run fence: a job for a run the document has moved on
  from changes nothing. A `perform/1` that returned `{:error, reason}` raises
  the same event, as an `Oban.PerformError`, but that failure is already on the
  document with a reason the classifier understands, so it is left alone.

  Telemetry runs a handler in the process that emits the event -- the job
  process after a rescued raise, Oban's producer task after a kill -- and
  detaches one that raises, so the write here is contained: a database error
  is logged and the document is left to startup recovery.

  Attached once by `Doctrans.Application`, before Oban starts.
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Lifecycle}
  alias Doctrans.Jobs.{DocumentExtractionJob, Keys}
  alias Doctrans.Processing.Run

  @handler_id "doctrans-extraction-crash-handler"
  @event [:oban, :job, :exception]

  @doc "Attaches the handler; already attached is the same success."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "The id the handler is attached under."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(@event, _measurements, %{job: %Oban.Job{} = job, error: error}, _config) do
    if job.worker == Oban.Worker.to_string(DocumentExtractionJob) and not performed?(error),
      do: mark_failed(job, error),
      else: :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # `perform/1` returned a failure: `Extraction` has already recorded it.
  defp performed?(%Oban.PerformError{}), do: true
  defp performed?(_error), do: false

  defp mark_failed(job, error) do
    document_id = Map.get(job.args, Keys.document_id())
    run_id = Map.get(job.args, Keys.run_id())

    _ =
      with %Document{} = document <- Documents.get_document(document_id),
           true <- Run.current?(document, run_id) do
        reason = {:extraction_job_crashed, [error: describe(error)]}

        Logger.error(
          "Extraction job #{job.id} for document #{document.id} ended without a verdict: " <>
            inspect(reason)
        )

        Lifecycle.fail(document, reason)
      end

    :ok
  rescue
    error in [Ecto.NoResultsError, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "Could not record the crash of extraction job #{job.id}: #{Exception.message(error)}"
      )

      :ok
  end

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error)
end
