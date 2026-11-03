defmodule Doctrans.Documents.Lifecycle do
  @moduledoc """
  The document status machine: every status a document can hold, and the named
  transitions between them.

  `Doctrans.Documents.ProcessingStatus` reads a document's state; this module
  writes it. Nothing else sets `status`: the schema validates the column, and
  every caller names a transition rather than a status string. A transition
  checks the status it starts from under the document lock, refuses an illegal
  move with a reason the caller can show or log, writes the new status and the
  `error_message` column in one update, and broadcasts `document_updated` once
  the write has committed. A caller inside a transaction of its own gets no
  broadcast from here -- announcing from inside it would advertise a change a
  rollback could still undo -- and publishes after its own commit instead, as
  `Doctrans.Processing.Cancellation` and `DocumentReprocessing` do.

  ## Statuses

  | status       | meaning                                                            |
  |--------------|--------------------------------------------------------------------|
  | `uploading`  | the row exists, its file is being stored, and no run has started   |
  | `queued`     | a run has started and its extraction job is waiting                |
  | `extracting` | the source is being converted and rendered into page images        |
  | `processing` | page jobs are extracting and translating                           |
  | `completed`  | every expected page succeeded                                      |
  | `error`      | extraction failed, or every page settled and at least one failed   |
  | `cancelled`  | the user stopped the run                                           |

  ## Transitions

  | transition           | from                                                | to                   |
  |----------------------|-----------------------------------------------------|----------------------|
  | `begin_extraction/1` | uploading, queued, extracting, processing, error    | extracting           |
  | `begin_processing/1` | uploading, queued, extracting                       | processing           |
  | `fail/2`             | uploading, queued, extracting, processing, error    | error                |
  | `settle/1`           | uploading, queued, extracting, processing, error    | completed or error   |
  | `cancel/1`           | uploading, queued, extracting, processing           | cancelled            |
  | `resume/1`           | processing, completed, error, cancelled             | processing           |
  | `requeue/2`          | uploading, completed, error, cancelled              | queued               |

  `requeue/2` is the one transition that starts a run, for a fresh upload and
  a reprocess alike: a document leaves `uploading` the moment its extraction
  job is enqueued, so `uploading` never has a job of its own, and a document
  with a run is `queued` or past it whichever path started the run.

  `completed` and `cancelled` are terminal for the pipeline: no job-side
  transition (`begin_*`, `fail/2`, `settle/1`) leaves them, so a job that was
  already executing when the user cancelled cannot report the document
  completed or failed afterwards. Only the user's own request leaves them --
  `requeue/2` starts a new run, `resume/1` queues page work under the current
  one. `begin_processing/1` is the one transition that answers `:ok` rather
  than a refusal when the document is already past it, because every page job
  calls it as it starts.

  A page failing for good writes nothing here. The document reaches `error`
  from page failures in `settle/1` alone, once every expected page has settled;
  `fail/2` is for failures before any page exists -- a stored upload that could
  not be cleaned up, a missing source, a conversion or a render failure.
  `error` therefore reads as "failed" only once nothing is running for the
  document, which `ProcessingStatus` asks Oban about.
  """

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page, Revision, Topics}
  alias Doctrans.Errors
  alias Doctrans.Processing.JobStates
  alias Doctrans.Repo

  @pre_processing ~w(uploading queued extracting)
  @in_flight @pre_processing ++ ~w(processing)
  @settled ~w(completed error cancelled)
  @awaiting_pages ~w(queued extracting)
  @run_startable ~w(uploading) ++ @settled
  @progress_reportable ~w(queued extracting processing completed error)

  # The from-list transitions, as the moduledoc tables them: the statuses each
  # is legal from, the status it lands on, and what it answers from anywhere
  # else. `begin_processing/1`, `settle/1` and `requeue/2` have their own shape.
  @transitions %{
    begin_extraction: {@in_flight ++ ~w(error), "extracting", :already_settled},
    fail: {@in_flight ++ ~w(error), "error", :already_settled},
    cancel: {@in_flight, "cancelled", :not_cancellable},
    resume: {~w(processing) ++ @settled, "processing", :already_processing}
  }

  @typedoc "How the document settled, or why it did not."
  @type verdict :: :completed | :failed | :retrying | :incomplete | :cancelled

  @typedoc "The reason a transition was refused."
  @type refusal :: :already_settled | :not_cancellable | :already_processing | :obsolete_run

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  @doc "True before any page job has run: the run is queued or rendering pages."
  @spec pre_processing?(Document.t()) :: boolean()
  def pre_processing?(%{status: status}), do: status in @pre_processing

  @doc "True while the run has not settled: anything a cancel can still stop."
  @spec in_flight?(Document.t()) :: boolean()
  def in_flight?(%{status: status}), do: status in @in_flight

  @doc "The rule `cancel/1` applies, for a UI deciding whether to offer it."
  @spec cancellable?(Document.t()) :: boolean()
  def cancellable?(document), do: in_flight?(document)

  @doc """
  True once the run has settled, so a fresh run may replace it.

  `cancelled` belongs here for the same reason `error` does: recovering from a
  stop without deleting the document is the point of offering one.
  """
  @spec reprocessable?(Document.t()) :: boolean()
  def reprocessable?(%{status: status}), do: status in @settled

  @doc "True when every expected page succeeded."
  @spec completed?(Document.t()) :: boolean()
  def completed?(%{status: status}), do: status == "completed"

  @doc "True when the user stopped the run."
  @spec cancelled?(Document.t()) :: boolean()
  def cancelled?(%{status: status}), do: status == "cancelled"

  @doc "True when the row records a failure; whether it is final is Oban's to say."
  @spec failed?(Document.t()) :: boolean()
  def failed?(%{status: status}), do: status == "error"

  @doc """
  True while a run's progress is worth reporting: one has started and the user
  has not stopped it. The rule a UI draws its progress bar under.

  `uploading` has no run to report on yet, and a `cancelled` document shows
  the stop itself rather than how far the run it interrupted had got.
  """
  @spec progress_reportable?(Document.t()) :: boolean()
  def progress_reportable?(%{status: status}), do: status in @progress_reportable

  @doc """
  Query-land predicate for a document whose run owes it page images: the run
  has started and extraction has not finished.

  Usable in an `Ecto.Query` `where` and on a loaded struct alike.
  """
  defmacro awaiting_pages?(document) do
    quote do: unquote(document).status in unquote(@awaiting_pages)
  end

  @doc """
  Query-land predicate for a document whose page jobs are under way.

  Usable in an `Ecto.Query` `where` and on a loaded struct alike.
  """
  defmacro processing?(document) do
    quote do: unquote(document).status == "processing"
  end

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc """
  The extraction job has picked the document up: converting and rendering begin.

  Legal from every state short of `completed` and `cancelled`, including
  `error`, which is where a failed extraction attempt leaves the document for
  its retry to find. Clears the diagnostic that attempt recorded.
  """
  @spec begin_extraction(Document.t()) :: {:ok, Document.t()} | {:error, refusal()}
  def begin_extraction(%Document{} = document), do: transition(document, :begin_extraction)

  @doc """
  The first page job has started: the document leaves its pre-processing states.

  Idempotent. A document already `processing`, or already settled, is left as
  it is and the call answers `:ok` without a broadcast, so every page job may
  call it as it starts. Given a page, the page names the run the call acts for,
  and one that has moved on answers `{:error, :obsolete_run}`.
  """
  @spec begin_processing(Page.t() | Document.t()) :: :ok | {:error, :obsolete_run}
  def begin_processing(%Page{} = page) do
    Revision.with_page(page, fn _ -> start_processing(Revision.lock(page.document_id)) end)
    |> publish()
  end

  def begin_processing(%Document{} = document) do
    document
    |> Revision.with_current(&start_processing/1)
    |> publish()
  end

  defp start_processing(%Document{} = document) do
    if pre_processing?(document), do: {:started, write(document, "processing")}, else: :ok
  end

  @doc """
  The run failed before any page did: a stored upload that could not be
  cleaned up, a missing source, a conversion or a render failure.

  Records the inspected `reason` in `error_message`. Legal from `error` as
  well, so a retry that fails again records its own diagnostic. Refused on a
  settled document with `:already_settled`, which a job logs and drops. Page
  failures do not come through here; see `settle/1`.
  """
  @spec fail(Document.t(), term()) :: {:ok, Document.t()} | {:error, refusal()}
  def fail(%Document{} = document, reason),
    do: transition(document, :fail, Errors.diagnostic(reason))

  @doc """
  The user stops the run. Refused with `:not_cancellable` once it has settled.
  """
  @spec cancel(Document.t()) :: {:ok, Document.t()} | {:error, refusal()}
  def cancel(%Document{} = document), do: transition(document, :cancel)

  @doc """
  Page work is queued again under the current run: a page reprocess, or a retry
  of the failed pages. The document is `processing` once more, and a settled
  document -- `completed`, `error` or `cancelled` alike -- is reopened.

  Refused with `:already_processing` while the run is still rendering pages,
  since there is no per-page work to replace until it has.
  """
  @spec resume(Document.t()) :: {:ok, Document.t()} | {:error, refusal()}
  def resume(%Document{} = document), do: transition(document, :resume)

  @doc """
  A run starts: the document is `queued` for extraction with the given run
  attributes (`Doctrans.Processing.Run.new_attrs/1`), its page count and
  diagnostic cleared. The one transition that starts a run, whether the
  extraction job of a fresh upload is being enqueued or a reprocess is
  replacing the run a settled document holds.

  Legal from `uploading` and from a settled status; refused with
  `:already_processing` while a run is under way.
  """
  @spec requeue(Document.t(), map()) :: {:ok, Document.t()} | {:error, refusal()}
  def requeue(%Document{} = document, run_attrs) do
    Revision.with_current(document, fn current ->
      if current.status in @run_startable do
        queued =
          current
          |> Ecto.Changeset.change(run_attrs)
          |> Ecto.Changeset.change(total_pages: nil)
          |> write("queued")

        {:ok, queued}
      else
        refuse(current, :requeue, :already_processing)
      end
    end)
    |> publish()
  end

  @doc """
  Decides the document's outcome from the state of its pages.

  A document is `completed` only when every expected page succeeded. One whose
  pages have all settled with at least one failure becomes `error`, with the failed page
  numbers as its diagnostic -- unless a failed page still has a job waiting to
  retry it (`:retrying`). Pages still outstanding leave it alone
  (`:incomplete`). A `completed` or `cancelled` document is not read again: it
  answers its verdict and nothing changes.

  The page or document names the run this acts for; one that has been reset,
  replaced or deleted since answers `{:error, :obsolete_run}` and changes
  nothing. A page is handed in by the job that has finished with it -- a
  success, or a failure Oban will not retry -- so a pending retry is looked for
  on the document's other failed pages, not on that one.
  """
  @spec settle(Page.t() | Document.t()) :: verdict() | {:error, :obsolete_run}
  def settle(%Page{} = page) do
    Revision.with_page(page, fn _ ->
      settle_locked(Revision.lock(page.document_id), page.id)
    end)
    |> publish()
  end

  def settle(%Document{} = document) do
    document
    |> Revision.with_current(&settle_locked(&1, nil))
    |> publish()
  end

  @doc """
  `settle/1` with no run guard.

  For a caller that holds no page or document of a run -- the startup recovery
  pass selects documents by status alone -- and so settles whichever run the
  document currently holds. A document that is gone is `:incomplete`.
  """
  @spec settle_unguarded(Ecto.UUID.t()) :: verdict()
  def settle_unguarded(document_id) do
    {:ok, result} =
      Repo.transaction(fn -> settle_locked(Revision.lock(document_id), nil) end)

    publish(result)
  end

  defp settle_locked(nil, _finished_page_id), do: :incomplete

  # Cancellation is the user's decision, and a job that was already executing
  # when it was taken still runs to completion. Reading the page states here
  # would let that straggler report the document completed or failed,
  # overturning a stop the user asked for and already saw take effect. A
  # completed document is terminal for the same reason: its verdict stands.
  defp settle_locked(document, finished_page_id) do
    cond do
      cancelled?(document) -> :cancelled
      completed?(document) -> :completed
      true -> settle_pages(document, finished_page_id)
    end
  end

  defp settle_pages(document, finished_page_id) do
    case Documents.completion_state(document.id) do
      :completed -> {:completed, write(document, "completed")}
      :failed -> settle_failed(document, finished_page_id)
      :incomplete -> :incomplete
    end
  end

  # Keep a scheduled retry distinguishable from terminal failure, and keep the
  # diagnostic an earlier settlement already recorded.
  defp settle_failed(document, finished_page_id) do
    cond do
      JobStates.retry_pending?(document.id, except: finished_page_id) ->
        :retrying

      failed?(document) ->
        :failed

      true ->
        {:failed, write(document, "error", Errors.diagnostic(page_failure_reason(document.id)))}
    end
  end

  defp page_failure_reason(document_id) do
    page_numbers = Documents.failed_page_numbers(document_id) |> Enum.join(", ")

    {:pages_failed, [page_numbers: page_numbers]}
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # One shape for every from-list transition: lock the row, compare its status
  # against the legal starting states in `@transitions`, write or refuse.
  defp transition(document, name, diagnostic \\ nil) do
    {from, to, refusal} = Map.fetch!(@transitions, name)

    Revision.with_current(document, fn current ->
      if current.status in from,
        do: {:ok, write(current, to, diagnostic)},
        else: refuse(current, name, refusal)
    end)
    |> publish()
  end

  defp refuse(document, name, refusal) do
    Logger.info(
      "Refused #{name} for document #{document.id} in status #{document.status}: #{refusal}"
    )

    {:error, refusal}
  end

  # The changeset is built from a status this module names and a diagnostic
  # already rendered to text, so the only way the update can fail is a lost
  # connection, which raises here as it would anywhere else.
  defp write(document_or_changeset, status, diagnostic \\ nil) do
    document_or_changeset
    |> Document.status_changeset(status, diagnostic)
    |> Repo.update!()
  end

  # Every write a transition makes comes back here tagged with the document it
  # produced; the tag says what the caller is told once the row is announced.
  # Anything else -- a refusal, a verdict that wrote nothing -- passes through.
  defp publish({:ok, document} = result), do: announce(document, result)
  defp publish({:started, document}), do: announce(document, :ok)
  defp publish({:completed, document}), do: announce(document, :completed)
  defp publish({:failed, document}), do: announce(document, :failed)
  defp publish(result), do: result

  defp announce(document, answer) do
    broadcast(document)
    answer
  end

  # Call after the guard's transaction returns, so subscribers read committed
  # state. A caller mid-transaction publishes after its own commit instead.
  defp broadcast(document) do
    unless Repo.in_transaction?(), do: Topics.broadcast_document_updated(document)
    :ok
  end
end
