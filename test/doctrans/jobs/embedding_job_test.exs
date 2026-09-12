defmodule Doctrans.Jobs.EmbeddingJobTest do
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents.{Chunk, Page, Pages}
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Search.{EmbeddingErrorStub, EmbeddingMock}

  # Three paragraphs of 200 words chunk into three chunks, each carrying exactly
  # one marker: the 50-word overlap between neighbours is filler. That makes a
  # marker a precise handle on one chunk's embedding call — and all three markers
  # together a handle on the page-level call, the only one that sees the whole text.
  @markers ~w(ALPHA BETA GAMMA)

  describe "enqueue_page/1" do
    test "runs on a bounded queue with attempts left for transient failures" do
      page = extracted_page("Queue configuration")
      job = page |> EmbeddingJob.page_args() |> EmbeddingJob.new()

      assert Ecto.Changeset.get_field(job, :queue) == "embedding_generation"
      assert Ecto.Changeset.get_field(job, :max_attempts) > 1
    end

    test "coalesces repeated requests for a revision and queues each new revision" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        page = extracted_page("Original text")

        assert {:ok, job} = EmbeddingJob.enqueue_page(page)
        assert {:ok, duplicate} = EmbeddingJob.enqueue_page(page)
        assert duplicate.id == job.id
        assert duplicate.conflict?
        assert Repo.aggregate(Oban.Job, :count) == 1

        {:ok, rewritten} =
          Pages.update_page_extraction(page, %{
            original_markdown: "Rewritten text",
            extraction_status: "completed"
          })

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

  describe "perform/1" do
    test "indexes the page it was queued for" do
      page = extracted_page("A page worth indexing")

      assert :ok = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      indexed = Repo.get!(Page, page.id)
      assert indexed.embedding_status == "completed"
      assert indexed.embedding != nil
      assert [%Chunk{embedding_status: "completed", embedding: vector}] = chunks_of(page)
      assert vector != nil
    end

    test "completes a page whose content produced no chunks" do
      document = document_fixture()
      page = page_fixture(document, %{extraction_status: "completed", original_markdown: ""})

      assert :ok = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      assert Repo.get!(Page, page.id).embedding_status == "completed"
      assert chunks_of(page) == []
    end

    test "cancels without writing vectors when a newer revision superseded it" do
      page = extracted_page("Obsolete text")
      args = EmbeddingJob.page_args(page)

      {:ok, _rewritten} =
        Pages.update_page_extraction(page, %{
          original_markdown: "Current text",
          extraction_status: "completed"
        })

      assert {:cancel, {:obsolete_revision, _}} = perform_job(EmbeddingJob, args)

      current = Repo.get!(Page, page.id)
      assert current.embedding_status == "pending"
      assert current.embedding == nil
      assert chunks_of(page) == []
    end

    test "cancels for a deleted page" do
      page = extracted_page("Deleted before indexing")
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
      page = extracted_page("Transient failure")
      args = EmbeddingJob.page_args(page)

      use_embedding_module(EmbeddingErrorStub)
      assert {:error, :timeout} = perform_job(EmbeddingJob, args)
      assert Repo.get!(Page, page.id).embedding_status == "error"

      use_embedding_module(EmbeddingMock)
      assert :ok = perform_job(EmbeddingJob, args)
      assert Repo.get!(Page, page.id).embedding_status == "completed"
      assert [%Chunk{embedding_status: "completed"}] = chunks_of(page)
    end

    test "cancels a permanent failure instead of retrying it" do
      page = extracted_page("Permanent failure")
      use_embedding_module(EmbeddingErrorStub)
      use_error_reason({:http_error, 400})

      assert {:cancel, {:http_error, [status: 400]}} =
               perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      assert Repo.get!(Page, page.id).embedding_status == "error"
    end

    test "keeps the chunks that succeeded when one of them fails" do
      page = extracted_page(multi_chunk_markdown())
      use_embedding_module(EmbeddingErrorStub)
      use_error_plan([{"BETA", :timeout}])

      assert {:error, :timeout} = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
      assert Repo.get!(Page, page.id).embedding_status == "error"

      assert [
               %Chunk{chunk_index: 0, embedding_status: "completed"},
               %Chunk{chunk_index: 1, embedding_status: "error", embedding: nil},
               %Chunk{chunk_index: 2, embedding_status: "completed"}
             ] = chunks_of(page)
    end

    test "retries a page whose failures are not all permanent" do
      page = extracted_page(multi_chunk_markdown())
      use_embedding_module(EmbeddingErrorStub)

      # The permanent failure comes first. Classifying the page on whichever
      # chunk failed first would cancel the job and strand the transient one.
      use_error_plan([{"ALPHA", {:http_error, 400}}, {"BETA", :timeout}])

      assert {:error, :timeout} = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
    end

    test "cancels a page only when every failure on it is permanent" do
      page = extracted_page(multi_chunk_markdown())
      use_embedding_module(EmbeddingErrorStub)
      use_error_plan(Enum.map(@markers, &{&1, {:http_error, 400}}))

      assert {:cancel, {:http_error, [status: 400]}} =
               perform_job(EmbeddingJob, EmbeddingJob.page_args(page))
    end

    test "a retry embeds only the chunks still missing a vector" do
      page = extracted_page(multi_chunk_markdown())
      args = EmbeddingJob.page_args(page)

      use_embedding_module(EmbeddingErrorStub)
      use_error_plan([{"BETA", :timeout}])
      assert {:error, :timeout} = perform_job(EmbeddingJob, args)
      assert [_, %Chunk{embedding: nil}, _] = chunks_of(page)

      # An empty plan fails nothing, so the second attempt is free to record
      # exactly which inputs it sends.
      use_error_plan([])
      observe_embedding_calls()
      assert :ok = perform_job(EmbeddingJob, args)

      assert [chunk_call, page_call] = embedding_calls()

      # The one chunk that had no vector, and nothing either side of it.
      assert String.contains?(chunk_call, "BETA")
      refute String.contains?(chunk_call, "ALPHA")
      refute String.contains?(chunk_call, "GAMMA")
      assert page_call == page.original_markdown

      assert Enum.all?(chunks_of(page), &(&1.embedding_status == "completed"))
      assert Repo.get!(Page, page.id).embedding_status == "completed"
    end

    test "does not mark a page indexed when its page-level vector was not written" do
      page = extracted_page(multi_chunk_markdown())
      use_embedding_module(EmbeddingErrorStub)

      # Only the page-level call carries every marker at once.
      use_error_plan([{@markers, :timeout}])

      assert {:error, :timeout} = perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      indexed = Repo.get!(Page, page.id)
      assert indexed.embedding == nil

      # Global search ranks on the page vector, so "completed" here would hide the
      # page from search with nothing left to notice or recover it.
      assert indexed.embedding_status == "error"

      # The chunk work is still kept, so the retry only owes the page-level call.
      assert Enum.all?(chunks_of(page), &(&1.embedding_status == "completed"))
    end
  end

  describe "retry lifecycle" do
    test "a reported failure leaves the job retryable and a cancel settles it" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        use_embedding_module(EmbeddingErrorStub)

        transient = extracted_page("Drained transient")
        assert {:ok, _} = EmbeddingJob.enqueue_page(transient)
        drain()
        assert job_state(transient) == "retryable"

        use_error_reason({:http_error, 400})
        permanent = extracted_page("Drained permanent")
        assert {:ok, _} = EmbeddingJob.enqueue_page(permanent)
        drain()
        assert job_state(permanent) == "cancelled"
      end)
    end

    test "reports retries on the embedding series the dashboard charts" do
      page = extracted_page("Retry telemetry")
      args = EmbeddingJob.page_args(page)
      use_embedding_module(EmbeddingErrorStub)
      attach_retry_telemetry()

      assert {:error, :timeout} = perform_job(EmbeddingJob, args, attempt: 1, max_attempts: 5)
      assert_received {:retry_event, [:doctrans, :retry, :attempt], %{type: :embedding}}

      assert {:error, :timeout} = perform_job(EmbeddingJob, args, attempt: 5, max_attempts: 5)
      assert_received {:retry_event, [:doctrans, :retry, :exhausted], %{type: :embedding}}
    end
  end

  defp extracted_page(text) do
    document = document_fixture()
    page_fixture(document, %{extraction_status: "completed", original_markdown: text})
  end

  defp multi_chunk_markdown do
    Enum.map_join(@markers, "\n\n", fn marker ->
      marker <> " " <> Enum.map_join(1..200, " ", &"word#{&1}")
    end)
  end

  defp chunks_of(page) do
    Chunk |> where([c], c.page_id == ^page.id) |> order_by([c], c.chunk_index) |> Repo.all()
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

  defp use_embedding_module(module) do
    put_test_env(:embedding_module, module)
  end

  defp use_error_reason(reason) do
    put_test_env(:embedding_error_reason, reason)
  end

  defp use_error_plan(plan) do
    put_test_env(:embedding_error_plan, plan)
  end

  defp observe_embedding_calls do
    put_test_env(:embedding_call_observer, self())
  end

  defp embedding_calls do
    Enum.reverse(collect_embedding_calls([]))
  end

  defp collect_embedding_calls(acc) do
    receive do
      {:embedding_call, text} -> collect_embedding_calls([text | acc])
    after
      0 -> acc
    end
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

  defp put_test_env(key, value) do
    previous = Application.fetch_env(:doctrans, key)
    Application.put_env(:doctrans, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doctrans, key, value)
        :error -> Application.delete_env(:doctrans, key)
      end
    end)
  end
end
