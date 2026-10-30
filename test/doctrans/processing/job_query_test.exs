defmodule Doctrans.Processing.JobQueryTest do
  use Doctrans.DataCase, async: true

  import Ecto.Query
  import Doctrans.Fixtures

  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, LlmProcessingJob, RunCleanupJob}
  alias Doctrans.Processing.JobQuery

  # Oban runs inline in the test env, so enqueueing through a worker would
  # execute it instead of leaving it in the state under test. Rows are staged
  # directly to pin a worker, args and state.
  defp stage(worker, args, state \\ "available") do
    now = DateTime.utc_now()

    Repo.insert!(%Oban.Job{
      worker: Oban.Worker.to_string(worker),
      queue: "staged",
      args: args,
      state: state,
      max_attempts: 3,
      scheduled_at: now,
      inserted_at: now
    })
  end

  defp ids(query), do: query |> select([j], j.id) |> Repo.all() |> Enum.sort()

  setup do
    document = document_with_pages_fixture(%{status: "processing"}, 2)
    other = document_with_pages_fixture(%{status: "processing"}, 1)
    %{document: document, pages: document.pages, other: other, other_page: hd(other.pages)}
  end

  describe "states" do
    test "waiting states are the active states short of executing" do
      assert "executing" in JobQuery.active_states()
      assert "suspended" in JobQuery.active_states()
      assert JobQuery.waiting_states() == JobQuery.active_states() -- ["executing"]
    end

    # The list is written out rather than derived, so pin it to Oban's own: a
    # state Oban adds would otherwise be neither active nor settled here.
    test "active states are every Oban state that is not settled" do
      oban_states = Oban.Job.states() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      settled = ~w(completed discarded cancelled)

      assert Enum.sort(JobQuery.active_states() ++ settled) == oban_states
    end
  end

  describe "document_jobs_query/2" do
    test "matches every active job holding the id, whatever its worker", ctx do
      args = %{"document_id" => ctx.document.id}

      active =
        for state <- JobQuery.active_states(), do: stage(DocumentExtractionJob, args, state)

      cleanup = stage(RunCleanupJob, args)

      _settled =
        for state <- ~w(completed discarded cancelled), do: stage(RunCleanupJob, args, state)

      _other = stage(DocumentExtractionJob, %{"document_id" => ctx.other.id})

      expected = Enum.sort(Enum.map([cleanup | active], & &1.id))
      assert ids(JobQuery.document_jobs_query(ctx.document.id)) == expected
    end

    test "narrows by worker and by states", ctx do
      args = %{"document_id" => ctx.document.id}
      waiting = stage(DocumentExtractionJob, args, "suspended")
      _running = stage(DocumentExtractionJob, args, "executing")
      cancelled = stage(DocumentExtractionJob, args, "cancelled")
      _cleanup = stage(RunCleanupJob, args, "suspended")

      query =
        JobQuery.document_jobs_query(ctx.document.id,
          worker: DocumentExtractionJob,
          states: JobQuery.waiting_states()
        )

      assert ids(query) == [waiting.id]

      owned = JobQuery.document_jobs_query(ctx.document.id, states: ~w(cancelled))
      assert ids(owned) == [cancelled.id]
    end

    test "correlates with an enclosing query through a dynamic selector", ctx do
      stage(DocumentExtractionJob, %{"document_id" => ctx.other.id})

      active =
        dynamic(type(parent_as(:document).id, :string))
        |> JobQuery.document_jobs_query(worker: DocumentExtractionJob)
        |> select(1)

      idle =
        from(d in Document, as: :document, where: not exists(active), select: d.id)
        |> Repo.all()

      assert ctx.document.id in idle
      refute ctx.other.id in idle
    end
  end

  describe "page_jobs_query/2" do
    test "takes a list of ids", ctx do
      [first, second] = ctx.pages
      matched = stage(LlmProcessingJob, %{"page_id" => first.id})
      indexed = stage(EmbeddingJob, %{"page_id" => first.id, "revision" => "r1"}, "retryable")
      _unlisted = stage(LlmProcessingJob, %{"page_id" => second.id})
      _other = stage(LlmProcessingJob, %{"page_id" => ctx.other_page.id})

      assert ids(JobQuery.page_jobs_query([first.id])) == Enum.sort([matched.id, indexed.id])
      assert ids(JobQuery.page_jobs_query([])) == []
    end

    test "takes a query selecting ids", ctx do
      [first, second] = ctx.pages
      jobs = for page <- [first, second], do: stage(LlmProcessingJob, %{"page_id" => page.id})
      _other = stage(LlmProcessingJob, %{"page_id" => ctx.other_page.id})

      page_ids =
        from p in Page, where: p.document_id == ^ctx.document.id, select: type(p.id, :string)

      query = JobQuery.page_jobs_query(page_ids, worker: LlmProcessingJob)
      assert ids(query) == Enum.sort(Enum.map(jobs, & &1.id))
    end

    test "narrows indexing jobs to one revision", ctx do
      [page | _] = ctx.pages
      current = stage(EmbeddingJob, %{"page_id" => page.id, "revision" => page.content_revision})

      _stale =
        stage(EmbeddingJob, %{"page_id" => page.id, "revision" => page.content_revision + 1})

      by_value =
        JobQuery.page_jobs_query([page.id], revision: Integer.to_string(page.content_revision))

      assert ids(by_value) == [current.id]

      correlated =
        dynamic(type(parent_as(:page).id, :string))
        |> JobQuery.page_jobs_query(
          worker: EmbeddingJob,
          revision: dynamic(type(parent_as(:page).content_revision, :string))
        )
        |> select([j], j.id)

      held =
        from(p in Page, as: :page, where: p.id == ^page.id, select: subquery(correlated))
        |> Repo.all()

      assert held == [current.id]
    end

    test "correlates with an enclosing query through a dynamic selector", ctx do
      [busy, free] = ctx.pages
      stage(LlmProcessingJob, %{"page_id" => busy.id}, "executing")

      active =
        dynamic(type(parent_as(:page).id, :string))
        |> JobQuery.page_jobs_query(worker: LlmProcessingJob)
        |> select(1)

      unowned =
        from(p in Page,
          as: :page,
          where: p.document_id == ^ctx.document.id,
          where: not exists(active),
          select: p.id
        )
        |> Repo.all()

      assert unowned == [free.id]
    end
  end

  describe "document_work_query/2" do
    test "joins extraction jobs with the listed page workers only", ctx do
      [page | _] = ctx.pages
      extraction = stage(DocumentExtractionJob, %{"document_id" => ctx.document.id}, "suspended")
      processing = stage(LlmProcessingJob, %{"page_id" => page.id})
      indexing = stage(EmbeddingJob, %{"page_id" => page.id, "revision" => "r1"})
      _cleanup = stage(RunCleanupJob, %{"document_id" => ctx.document.id})
      _done = stage(LlmProcessingJob, %{"page_id" => page.id}, "completed")
      _other = stage(LlmProcessingJob, %{"page_id" => ctx.other_page.id})

      content = JobQuery.document_work_query(ctx.document.id, [LlmProcessingJob])
      assert ids(content) == Enum.sort([extraction.id, processing.id])

      both = JobQuery.document_work_query(ctx.document.id, [LlmProcessingJob, EmbeddingJob])
      assert ids(both) == Enum.sort([extraction.id, processing.id, indexing.id])
    end
  end
end
