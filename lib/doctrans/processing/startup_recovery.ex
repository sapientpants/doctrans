defmodule Doctrans.Processing.StartupRecovery do
  @moduledoc """
  Recovers work in batches of at most 50 jobs. Cursors keep each startup pass
  finite, while active Oban jobs are left to Oban's own retry/recovery lifecycle.

  The final phase queues nothing: it reconciles documents whose pages all
  settled while the document row never learned of it.
  """

  require Logger

  import Ecto.Query
  import Doctrans.Documents.Page, only: [settled?: 1]

  alias Doctrans.Documents.{Document, Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, Keys, LlmProcessingJob}
  alias Doctrans.Processing.{DocumentOrchestrator, Run}
  alias Doctrans.Repo

  @batch_size 50
  @active_states ~w(available scheduled executing retryable suspended)
  # A cancelled indexing job reported that the revision it held cannot be indexed
  # as it stands. Re-queueing that same revision on every boot would repeat the
  # failure and the API calls it costs, so a cancelled run settles the revision;
  # a content change produces a new one, which is recovered normally. Exhausted
  # retries (`discarded`) are deliberately not settled: those failures were
  # classified retryable, and a restart is a fair new attempt.
  @settled_states ~w(cancelled)
  @indexing_owned_states @active_states ++ @settled_states
  @document_id_match "?->>'#{Keys.document_id()}' = ?::text"
  @page_id_match "?->>'#{Keys.page_id()}' = ?::text"
  @revision_match "?->>'#{Keys.revision()}' = ?::text"

  @typedoc "Where the next batch resumes: a phase with the last id handled, or :done."
  @type cursor ::
          {:documents, Ecto.UUID.t() | nil}
          | {:pages, Ecto.UUID.t() | nil}
          | {:embeddings, Ecto.UUID.t() | nil}
          | {:completion, Ecto.UUID.t() | nil}
          | :done

  @doc "Returns the next cursor, or :done when the startup pass is complete."
  @spec run_batch(cursor()) :: cursor()
  def run_batch(cursor \\ {:documents, nil})

  def run_batch({:documents, after_id}) do
    worker = Oban.Worker.to_string(DocumentExtractionJob)

    rows =
      from(d in Document,
        as: :document,
        where: d.status in ["queued", "extracting"],
        where:
          not exists(
            from(j in Oban.Job,
              where: j.worker == ^worker and j.state in ^@active_states,
              where: fragment(@document_id_match, j.args, parent_as(:document).id),
              select: 1
            )
          ),
        select: %{id: d.id}
      )
      |> fetch_batch(after_id)

    Repo.transact(fn ->
      Enum.each(rows, &recover_document/1)
      {:ok, :queued}
    end)
    |> unwrap!()

    next_cursor(rows, :documents, {:pages, nil})
  end

  def run_batch({:pages, after_id}) do
    rows =
      from(p in Page,
        as: :page,
        join: d in Document,
        on: d.id == p.document_id,
        where: d.status == "processing",
        where: p.extraction_status != "completed" or p.translation_status != "completed",
        select: %{
          id: p.id,
          document_id: p.document_id
        }
      )
      |> without_active_job(LlmProcessingJob)
      |> fetch_batch(after_id)

    pages =
      Repo.transact(fn ->
        pages = Enum.flat_map(rows, &recover_page/1)
        {:ok, pages}
      end)
      |> unwrap!()

    Enum.each(pages, &Topics.broadcast_page_update/1)
    next_cursor(rows, :pages, {:embeddings, nil})
  end

  # Indexing is recovered for every extracted page, whatever its document's status:
  # a document that finished translating still loses semantic search and chat when
  # its indexing was interrupted, and the page phase above never looks at it.
  def run_batch({:embeddings, after_id}) do
    rows =
      from(p in Page,
        as: :page,
        where: p.extraction_status == "completed",
        where: p.embedding_status != "completed",
        select: %{id: p.id}
      )
      |> without_indexing_job()
      |> fetch_batch(after_id)

    Enum.each(rows, &recover_embedding/1)

    next_cursor(rows, :embeddings, {:completion, nil})
  end

  # A page's last write and its document's completion are separate transactions,
  # so a crash between them leaves a `processing` document whose pages have all
  # settled. Nothing else revisits it: the page phase above finds no page to
  # resume, and a replayed page job that skips both stages used to return
  # without rechecking. This phase resolves those documents from the rows that
  # are already saved — the states C03 defined — and so queues no work and makes
  # no model request.
  #
  # It runs last on purpose. The page phase resets a failed page to `pending`
  # and queues a retry, which unsettles the document again; settling failures
  # before that ran would report an error for a page about to be retried.
  def run_batch({:completion, after_id}) do
    rows =
      from(d in Document,
        as: :document,
        where: d.status == "processing",
        # A document that does not know how many pages to expect is never
        # terminal, so there is nothing for this phase to resolve.
        where: d.total_pages > 0,
        where:
          not exists(
            from(p in Page,
              where: p.document_id == parent_as(:document).id,
              where: not settled?(p),
              select: 1
            )
          ),
        select: %{id: d.id}
      )
      |> fetch_batch(after_id)

    Enum.each(rows, &reconcile_completion/1)

    next_cursor(rows, :completion, :done)
  end

  # The orchestrator holds the rules: it locks the document, completes it only
  # when every expected page succeeded, records the failed page numbers when
  # they all settled with a failure, and leaves a document alone while a retry
  # of a failed page is still pending.
  #
  # One document per row, contained like the phases above: this phase commits
  # per document rather than per batch, so an escaping error would abandon the
  # cursor mid-batch and take the worker down with it. The worker restarts the
  # whole pass from the first phase, and the inconsistency this phase exists to
  # heal is durable, so an uncontained row would be replayed on every restart.
  #
  # Only the database errors are caught, matching `Worker.queue_status/0`. The
  # orchestrator's `{:ok, _} =` matches are self-consistent under the document
  # lock it holds, so a MatchError from there would be a logic bug worth
  # surfacing rather than a row worth skipping.
  defp reconcile_completion(row) do
    _ = DocumentOrchestrator.check_document_completion(row.id)
    :ok
  rescue
    error in [Ecto.NoResultsError, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "Startup recovery could not reconcile document #{row.id}: #{Exception.message(error)}"
      )

      :ok
  end

  # One page per transaction: these rows are independent, so a row that cannot be
  # queued should cost that page rather than the whole batch, and the lock below
  # is then held across one insert instead of fifty.
  #
  # Read the revision under that lock, so a page rewritten since it was selected
  # is queued at the revision it now holds rather than one the job would cancel on.
  defp recover_embedding(row) do
    Repo.transact(fn ->
      page = from(p in Page, where: p.id == ^row.id, lock: "FOR UPDATE") |> Repo.one()

      case page do
        %Page{extraction_status: "completed", embedding_status: status}
        when status != "completed" ->
          page
          |> EmbeddingJob.page_args()
          |> EmbeddingJob.new(meta: %{recovered: true})
          |> Oban.insert()

        _ ->
          {:ok, :skipped}
      end
    end)
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Startup recovery could not queue indexing for page #{row.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp recover_document(row) do
    locked = from(d in Document, where: d.id == ^row.id, lock: "FOR UPDATE") |> Repo.one()

    case locked do
      %Document{status: status} = current when status in ["queued", "extracting"] ->
        Run.args(current)
        |> DocumentExtractionJob.new(meta: %{recovered: true})
        |> Oban.insert!()

      _ ->
        :ok
    end
  end

  # `EmbeddingJob` is keyed on the page *and* its revision, so unlike a page-keyed
  # job an active one does not necessarily own the page's current work: a job
  # holding a superseded revision cancels without indexing anything. Matching the
  # revision as well is what stops such a job from suppressing recovery of the
  # revision that replaced it — the failure R01 exists to close.
  defp without_indexing_job(query) do
    worker = Oban.Worker.to_string(EmbeddingJob)

    from(p in query,
      where:
        not exists(
          from(j in Oban.Job,
            where: j.worker == ^worker and j.state in ^@indexing_owned_states,
            where: fragment(@page_id_match, j.args, parent_as(:page).id),
            where: fragment(@revision_match, j.args, parent_as(:page).content_revision),
            select: 1
          )
        )
    )
  end

  # A page already owned by an active job of `module` is that job's to finish.
  defp without_active_job(query, module) do
    worker = Oban.Worker.to_string(module)

    from(p in query,
      where:
        not exists(
          from(j in Oban.Job,
            where: j.worker == ^worker and j.state in ^@active_states,
            where: fragment(@page_id_match, j.args, parent_as(:page).id),
            select: 1
          )
        )
    )
  end

  defp fetch_batch(query, nil) do
    query |> order_by([row], asc: row.id) |> limit(@batch_size) |> Repo.all()
  end

  defp fetch_batch(query, after_id) do
    query |> where([row], row.id > ^after_id) |> fetch_batch(nil)
  end

  defp recover_page(row) do
    # Lock the parent first so stopping/deleting a document cannot race recovery.
    document =
      from(d in Document, where: d.id == ^row.document_id, lock: "FOR UPDATE")
      |> Repo.one()

    page = from(p in Page, where: p.id == ^row.id, lock: "FOR UPDATE") |> Repo.one()

    case {document, page} do
      {%Document{status: "processing"} = document, %Page{} = page} ->
        maybe_recover_page(page, document)

      _ ->
        []
    end
  end

  defp maybe_recover_page(
         %Page{extraction_status: "completed", translation_status: "completed"},
         _document
       ),
       do: []

  defp maybe_recover_page(page, document) do
    # Insert before changing statuses: uniqueness also covers jobs queued since
    # candidate selection. A conflicting job owns this page's processing state.
    job =
      page
      |> LlmProcessingJob.page_args(
        page.processing_generation,
        Run.page_model_args(page, document)
      )
      |> LlmProcessingJob.new(priority: 2, meta: %{recovered: true})
      |> Oban.insert!()

    if job.conflict? do
      []
    else
      changes = %{
        extraction_status: recovered_status(page.extraction_status),
        translation_status: recovered_status(page.translation_status)
      }

      [page |> Ecto.Changeset.change(changes) |> Repo.update!()]
    end
  end

  defp recovered_status("completed"), do: "completed"
  defp recovered_status(_status), do: "pending"

  defp next_cursor(rows, phase, _fallback) when length(rows) == @batch_size,
    do: {phase, List.last(rows).id}

  defp next_cursor(_rows, _phase, fallback), do: fallback

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: raise("Startup recovery failed: #{inspect(reason)}")
end
