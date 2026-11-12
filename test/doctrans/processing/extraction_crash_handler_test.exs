defmodule Doctrans.Processing.ExtractionCrashHandlerTest do
  @moduledoc """
  The handler at its interface: Oban's `[:oban, :job, :exception]` event for an
  extraction job, as `Oban.Queues.Executor` and the producer emit it.

  The events are executed by hand. Oban's own timeout exits the job process,
  which under inline testing is the test process; what the handler does with
  the event is the same whichever process emits it.
  """
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Processing.ExtractionCrashHandler

  import Doctrans.Fixtures

  @event [:oban, :job, :exception]

  test "is attached at boot" do
    ids = @event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert ExtractionCrashHandler.handler_id() in ids
  end

  test "attaching again is the same success" do
    assert ExtractionCrashHandler.attach() == :ok
  end

  describe "an extraction job that ended without a verdict" do
    test "fails its document with the error named, under the run it held" do
      document = document_fixture(%{status: "extracting"})
      Topics.subscribe_document(document.id)
      job = extraction_job(document, document.processing_run_id)

      error = Oban.TimeoutError.exception({DocumentExtractionJob, 3_900_000})
      emit(job, error)

      saved = Documents.get_document!(document.id)
      assert saved.status == "error"
      assert saved.error_message =~ "extraction_job_crashed"
      assert saved.error_message =~ "timed out after 3900000ms"
      assert_received {:document_updated, %{status: "error"}}
    end

    test "names a crash that was not an exception" do
      document = document_fixture(%{status: "extracting"})
      job = extraction_job(document, document.processing_run_id)

      # The producer reports a job process that exited for any other reason
      # with that reason as it is.
      emit(job, :killed)

      saved = Documents.get_document!(document.id)
      assert saved.status == "error"
      assert saved.error_message =~ ":killed"
    end

    test "leaves a document whose run has moved on alone" do
      document = document_fixture(%{status: "extracting"})
      job = extraction_job(document, Uniq.UUID.uuid7())

      emit(job, Oban.TimeoutError.exception({DocumentExtractionJob, 3_900_000}))

      assert Documents.get_document!(document.id).status == "extracting"
    end

    test "leaves a document that is gone alone" do
      job = extraction_job(%{id: Uniq.UUID.uuid7()}, nil)

      assert :ok ==
               ExtractionCrashHandler.handle_event(
                 @event,
                 %{},
                 %{job: job, error: RuntimeError.exception("gone")},
                 nil
               )
    end
  end

  describe "events that are not its to act on" do
    test "a failure perform/1 returned is already recorded by the run itself" do
      document = document_fixture(%{status: "error", error_message: ":document_file_not_found"})
      job = extraction_job(document, document.processing_run_id)

      emit(job, Oban.PerformError.exception({DocumentExtractionJob, {:error, :boom}}))

      assert Documents.get_document!(document.id).error_message == ":document_file_not_found"
    end

    test "another worker's exception changes nothing" do
      document = document_fixture(%{status: "processing"})

      job = %Oban.Job{
        id: 1,
        worker: Oban.Worker.to_string(LlmProcessingJob),
        args: %{"document_id" => document.id}
      }

      emit(job, Oban.TimeoutError.exception({LlmProcessingJob, 1_000}))

      assert Documents.get_document!(document.id).status == "processing"
    end
  end

  defp extraction_job(document, run_id) do
    %Oban.Job{
      id: 1,
      worker: Oban.Worker.to_string(DocumentExtractionJob),
      args: %{"document_id" => document.id, "run_id" => run_id}
    }
  end

  defp emit(job, error) do
    :telemetry.execute(@event, %{duration: 0}, %{
      job: job,
      error: error,
      reason: error,
      kind: :error,
      state: :failure
    })
  end
end
