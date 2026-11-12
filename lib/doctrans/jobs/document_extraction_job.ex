defmodule Doctrans.Jobs.DocumentExtractionJob do
  @moduledoc """
  The Oban side of extraction.

  `Doctrans.Processing.Run.start/2` inserts this job as it starts a fresh
  upload's run; performing hands the document to
  `Doctrans.Processing.Extraction.run/2`, which does the work and makes the
  document's transitions. What is decided here is only what Oban needs to
  know: whether the job still names the document's current run, and whether
  a failure is worth another attempt.
  """

  use Oban.Worker,
    queue: :pdf_extraction,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Config.{DocumentConversion, PdfExtraction}
  alias Doctrans.Documents
  alias Doctrans.Jobs.Keys
  alias Doctrans.Processing.{Extraction, Run}
  alias Doctrans.Resilience.ErrorClassifier

  @document_id_key Keys.document_id()

  # Oban waits forever by default, so the job carries a ceiling -- but the
  # ceiling is an outer guard, not the budget. The budget is
  # `PdfExtraction.job_timeout/0`: `perform/1` arms it as it begins and
  # `Extraction` clamps every page render against it, so a document that runs
  # out fails cleanly with its finished pages preserved, and the retry resumes
  # rather than restarts. Oban arms this timer before `perform/1` and kills the
  # job process when it fires, which no `Lifecycle` transition survives; the
  # guard is therefore strictly wider than the budget plus the two steps the
  # budget does not clamp -- the LibreOffice conversion and the page count run
  # to their own ceilings -- so that the budget is the deadline that fires.
  # `Doctrans.Processing.ExtractionCrashHandler` covers the guard if it ever does.
  @guard_margin :timer.minutes(1)

  @impl true
  def timeout(_job) do
    PdfExtraction.job_timeout() + DocumentConversion.timeout() + PdfExtraction.info_timeout() +
      @guard_margin
  end

  # A document row that is gone stays gone, so the job is cancelled rather than
  # spent on retries that find the same absence.
  @impl true
  def perform(%Oban.Job{args: %{@document_id_key => document_id} = args}) do
    # The budget starts here, before the source is located and converted,
    # rather than when the first page renders: counted from any later point it
    # would outlast the guard above.
    deadline = Extraction.budget_from_now()

    case Documents.get_document(document_id) do
      nil -> {:cancel, :document_not_found}
      document -> document |> perform_current(args, deadline) |> cancel_permanent()
    end
  end

  # A failure that cannot come out differently on a retry — the document is over
  # a limit, a tool is not installed, the source file is gone — is cancelled with
  # the reason intact. Retrying it would burn the document's remaining attempts
  # and occupy the single extraction slot to reach the same answer.
  defp cancel_permanent({:error, reason}) do
    if ErrorClassifier.retryable?(reason), do: {:error, reason}, else: {:cancel, reason}
  end

  defp cancel_permanent(result), do: result

  # A run the document has moved on from is not this job's to act on, and is
  # dropped as a success; `Extraction` makes the same call for a run replaced
  # or settled while it was under way.
  defp perform_current(document, args, deadline) do
    if Run.current?(document, Map.get(args, Keys.run_id())),
      do: Extraction.run(document, deadline: deadline),
      else: :ok
  end
end
