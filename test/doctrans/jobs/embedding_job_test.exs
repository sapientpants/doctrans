defmodule Doctrans.Jobs.EmbeddingJobTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Config.Embedding
  alias Doctrans.Documents.{Chunk, Page, PageLifecycle}
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Search.EmbeddingMocks

  # The markers `multi_chunk_markdown/1` plants, one per chunk: a handle on one
  # chunk's embedding call, and all three together on the page-level call.
  @markers ~w(ALPHA BETA GAMMA)

  describe "enqueue_page/1" do
    test "runs on a bounded queue with attempts left for transient failures" do
      page = extracted_page_fixture("Queue configuration")
      job = page |> EmbeddingJob.page_args() |> EmbeddingJob.new()

      assert Ecto.Changeset.get_field(job, :queue) == "embedding_generation"
      assert Ecto.Changeset.get_field(job, :max_attempts) > 1
    end

    test "coalesces repeated requests for a revision and queues each new revision" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        page = extracted_page_fixture("Original text")

        assert {:ok, job} = EmbeddingJob.enqueue_page(page)
        assert {:ok, duplicate} = EmbeddingJob.enqueue_page(page)
        assert duplicate.id == job.id
        assert duplicate.conflict?
        assert Repo.aggregate(Oban.Job, :count) == 1

        {:ok, rewritten} =
          PageLifecycle.complete(page, :extraction, %{markdown: "Rewritten text"})

        assert rewritten.content_revision > page.content_revision
        assert {:ok, next} = EmbeddingJob.enqueue_page(rewritten)
        refute next.conflict?
        assert Repo.aggregate(Oban.Job, :count) == 2
      end)
    end

    test "keys uniqueness on the page as well as the revision" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture()

        first =
          page_fixture(document, %{
            page_number: 1,
            extraction_status: "completed",
            original_markdown: "A"
          })

        second =
          page_fixture(document, %{
            page_number: 2,
            extraction_status: "completed",
            original_markdown: "B"
          })

        # Fresh pages share a revision, so dropping the page from the unique keys
        # would collapse an entire document into one job.
        assert first.content_revision == second.content_revision

        assert {:ok, _} = EmbeddingJob.enqueue_page(first)
        assert {:ok, other} = EmbeddingJob.enqueue_page(second)
        refute other.conflict?
        assert Repo.aggregate(Oban.Job, :count) == 2
      end)
    end
  end

  describe "timeout/1" do
    test "is an outer guard wider than the budget and the window its last call may outlive it by" do
      # Oban arms its timer before `perform/1` and kills the job process when it
      # fires, with no verdict written for the page. The budget is what fails
      # the page cleanly, so the guard has to outlast it -- and the last call,
      # which may return one receive window after the budget it was clamped to.
      timeout = EmbeddingJob.timeout(%Oban.Job{args: %{}})

      assert is_integer(timeout)
      assert timeout > Embedding.job_timeout() + Embedding.timeout()
    end
  end

  describe "perform/1" do
    test "arms the indexing budget as it begins and hands it to every embedding call" do
      EmbeddingMocks.observe()
      page = extracted_page_fixture(multi_chunk_markdown(@markers))

      assert :ok = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      calls = EmbeddingMocks.calls()
      # Three chunks and the page-level vector, each under the one budget.
      assert length(calls) == 4

      for {_text, opts} <- calls do
        deadline = Keyword.fetch!(opts, :deadline)
        assert deadline > 0
        assert deadline <= Embedding.job_timeout()
        assert deadline <= Embedding.deadline()
      end
    end

    test "indexes the page it was queued for" do
      page = extracted_page_fixture("A page worth indexing")

      assert :ok = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      indexed = Repo.get!(Page, page.id)
      assert indexed.embedding_status == "completed"
      assert indexed.embedding != nil
      assert [%Chunk{embedding_status: "completed", embedding: vector}] = page_chunks(page)
      assert vector != nil
    end

    test "completes a page whose content produced no chunks" do
      document = document_fixture()
      page = page_fixture(document, %{extraction_status: "completed", original_markdown: ""})

      assert :ok = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      assert Repo.get!(Page, page.id).embedding_status == "completed"
      assert page_chunks(page) == []
    end

    test "cancels without writing vectors when a newer revision superseded it" do
      page = extracted_page_fixture("Obsolete text")
      args = EmbeddingJob.page_args(page)

      {:ok, _rewritten} =
        PageLifecycle.complete(page, :extraction, %{markdown: "Current text"})

      assert {:cancel, {:obsolete_revision, _}} = perform_job(EmbeddingJob, args)

      current = Repo.get!(Page, page.id)
      assert current.embedding_status == "pending"
      assert current.embedding == nil
      assert page_chunks(page) == []
    end

    test "cancels for a deleted page" do
      page = extracted_page_fixture("Deleted before indexing")
      args = EmbeddingJob.page_args(page)
      Repo.delete!(page)

      assert {:cancel, :page_not_found} = perform_job(EmbeddingJob, args)
    end

    test "cancels when extraction is not complete" do
      document = document_fixture()
      page = page_fixture(document, %{extraction_status: "processing"})

      assert {:cancel, :extraction_incomplete} =
               perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
    end

    test "reports a transient failure so the attempt is retried, and succeeds on retry" do
      page = extracted_page_fixture("Transient failure")
      args = EmbeddingJob.page_args(page)

      EmbeddingMocks.fail()
      assert {:error, :timeout} = perform_job(EmbeddingJob, args)
      assert Repo.get!(Page, page.id).embedding_status == "error"

      EmbeddingMocks.succeed()
      assert :ok = perform_job(EmbeddingJob, args)
      assert Repo.get!(Page, page.id).embedding_status == "completed"
      assert [%Chunk{embedding_status: "completed"}] = page_chunks(page)
    end

    test "cancels a permanent failure instead of retrying it" do
      page = extracted_page_fixture("Permanent failure")
      EmbeddingMocks.fail({:http_error, 400})

      assert {:cancel, {:http_error, [status: 400]}} =
               perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      assert Repo.get!(Page, page.id).embedding_status == "error"
    end

    test "keeps the chunks that succeeded when one of them fails" do
      page = extracted_page_fixture(multi_chunk_markdown(@markers))
      EmbeddingMocks.fail_matching([{"BETA", :timeout}])

      assert {:error, :timeout} = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
      assert Repo.get!(Page, page.id).embedding_status == "error"

      assert [
               %Chunk{chunk_index: 0, embedding_status: "completed"},
               %Chunk{chunk_index: 1, embedding_status: "error", embedding: nil},
               %Chunk{chunk_index: 2, embedding_status: "completed"}
             ] = page_chunks(page)
    end

    test "retries a page whose failures are not all permanent" do
      page = extracted_page_fixture(multi_chunk_markdown(@markers))

      # The permanent failure comes first. Classifying the page on whichever
      # chunk failed first would cancel the job and strand the transient one.
      EmbeddingMocks.fail_matching([{"ALPHA", {:http_error, 400}}, {"BETA", :timeout}])

      assert {:error, :timeout} = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
    end

    test "cancels a page only when every failure on it is permanent" do
      page = extracted_page_fixture(multi_chunk_markdown(@markers))
      EmbeddingMocks.fail_matching(Enum.map(@markers, &{&1, {:http_error, 400}}))

      assert {:cancel, {:http_error, [status: 400]}} =
               perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
    end

    test "a retry embeds only the chunks still missing a vector" do
      page = extracted_page_fixture(multi_chunk_markdown(@markers))
      args = EmbeddingJob.page_args(page)

      EmbeddingMocks.fail_matching([{"BETA", :timeout}])
      assert {:error, :timeout} = perform_job(EmbeddingJob, args)
      assert [_, %Chunk{embedding: nil}, _] = page_chunks(page)

      # The observing stub fails nothing, so the second attempt is free to
      # record exactly which inputs it sends.
      EmbeddingMocks.observe()
      assert :ok = perform_job(EmbeddingJob, args)

      assert [{chunk_call, _opts}, {page_call, _page_opts}] = EmbeddingMocks.calls()

      # The one chunk that had no vector, and nothing either side of it.
      assert String.contains?(chunk_call, "BETA")
      refute String.contains?(chunk_call, "ALPHA")
      refute String.contains?(chunk_call, "GAMMA")
      assert page_call == page.original_markdown

      assert Enum.all?(page_chunks(page), &(&1.embedding_status == "completed"))
      assert Repo.get!(Page, page.id).embedding_status == "completed"
    end

    test "does not mark a page indexed when its page-level vector was not written" do
      page = extracted_page_fixture(multi_chunk_markdown(@markers))

      # Only the page-level call carries every marker at once.
      EmbeddingMocks.fail_matching([{@markers, :timeout}])

      assert {:error, :timeout} = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      indexed = Repo.get!(Page, page.id)
      assert indexed.embedding == nil

      # Global search ranks on the page vector, so "completed" here would hide the
      # page from search with nothing left to notice or recover it.
      assert indexed.embedding_status == "error"

      # The chunk work is still kept, so the retry only owes the page-level call.
      assert Enum.all?(page_chunks(page), &(&1.embedding_status == "completed"))
    end
  end

  describe "retry lifecycle" do
    test "a reported failure leaves the job retryable and a cancel settles it" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        EmbeddingMocks.fail()

        transient = extracted_page_fixture("Drained transient")
        assert {:ok, _} = EmbeddingJob.enqueue_page(transient)
        drain()
        assert job_state(transient) == "retryable"

        EmbeddingMocks.fail({:http_error, 400})
        permanent = extracted_page_fixture("Drained permanent")
        assert {:ok, _} = EmbeddingJob.enqueue_page(permanent)
        drain()
        assert job_state(permanent) == "cancelled"
      end)
    end

    test "reports retries on the embedding series the dashboard charts" do
      page = extracted_page_fixture("Retry telemetry")
      args = EmbeddingJob.page_args(page)
      EmbeddingMocks.fail()
      attach_retry_telemetry()

      # Telemetry is VM-global, so a concurrent test's embedding retries reach
      # this handler too: match this test's page, not just the series.
      page_id = page.id

      assert {:error, :timeout} = perform_job(EmbeddingJob, args, attempt: 1, max_attempts: 5)

      assert_received {:retry_event, [:doctrans, :retry, :attempt],
                       %{type: :embedding, page_id: ^page_id}}

      assert {:error, :timeout} = perform_job(EmbeddingJob, args, attempt: 5, max_attempts: 5)

      assert_received {:retry_event, [:doctrans, :retry, :exhausted],
                       %{type: :embedding, page_id: ^page_id}}
    end
  end

  defp drain, do: Oban.drain_queue(queue: :embedding_generation, with_recursion: false)

  defp job_state(page) do
    page_id = page.id

    Oban.Job
    |> where([j], j.worker == "Doctrans.Jobs.EmbeddingJob")
    |> where([j], fragment("?->>'page_id' = ?", j.args, ^page_id))
    |> Repo.one!()
    |> Map.fetch!(:state)
  end

  defp attach_retry_telemetry do
    owner = self()
    handler = "retry-telemetry-#{inspect(owner)}"
    events = [[:doctrans, :retry, :attempt], [:doctrans, :retry, :exhausted]]

    :telemetry.attach_many(
      handler,
      events,
      fn event, _measurements, metadata, _config ->
        send(owner, {:retry_event, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
