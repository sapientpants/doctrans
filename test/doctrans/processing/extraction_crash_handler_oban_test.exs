defmodule Doctrans.Processing.ExtractionCrashHandlerObanTest do
  @moduledoc """
  The handler behind a real Oban queue: a job process that dies with
  `Oban.TimeoutError`, the exit Oban's guard delivers when it fires, reaches the
  handler through the producer's own report, and the document is failed.

  The timer is the one thing replaced. The guard is minutes wide, so the test
  sends the job process the exit `:timer.exit_after/2` would; everything from
  the producer's `:DOWN` to the telemetry event is Oban's.
  """
  # `async: false`: the job runs in a process Oban started, which only a global
  # Mox stub reaches, and the sandbox connection is shared with it.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.PdfExtractorMock

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  @oban __MODULE__.Oban

  test "a job Oban killed fails its document through the producer's report" do
    document = document_fixture()
    document_source_fixture(document)
    Topics.subscribe_document(document.id)
    owner = self()

    # The run blocks at its first extractor call, the document already
    # `extracting` and the job process known.
    Mox.stub(PdfExtractorMock, :get_page_count, fn _pdf_path ->
      send(owner, {:running, self()})
      Process.sleep(:infinity)
    end)

    start_supervised!(
      {Oban,
       name: @oban,
       repo: Repo,
       testing: :disabled,
       notifier: Oban.Notifiers.Isolated,
       plugins: false,
       stage_interval: 50,
       shutdown_grace_period: 100,
       queues: [pdf_extraction: 1]}
    )

    {:ok, job} =
      %{"document_id" => document.id, "run_id" => document.processing_run_id}
      |> DocumentExtractionJob.new()
      |> then(&Oban.insert(@oban, &1))

    assert_receive {:running, job_pid}, 5_000
    assert Documents.get_document!(document.id).status == "extracting"

    log =
      capture_log(fn ->
        Process.exit(job_pid, Oban.TimeoutError.exception({DocumentExtractionJob, 1}))
        assert_receive {:document_updated, %{status: "error"}}, 5_000
      end)

    saved = Documents.get_document!(document.id)
    assert saved.status == "error"
    assert saved.error_message =~ "extraction_job_crashed"
    assert saved.error_message =~ "timed out after 1ms"
    assert log =~ "ended without a verdict"

    # Oban's side of the report: the attempt is recorded and the job is left
    # for a retry, which resumes from the pages this one kept.
    retried = Repo.get!(Oban.Job, job.id)
    assert retried.state == "retryable"
    assert [%{"error" => error}] = retried.errors
    assert error =~ "Oban.TimeoutError"
  end
end
