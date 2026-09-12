defmodule Doctrans.Jobs.EmbeddingJobTest do
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents.{Chunk, Page, Pages}
  alias Doctrans.Jobs.EmbeddingJob

  describe "enqueue_page/2" do
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

      use_embedding_module(Doctrans.Search.EmbeddingErrorStub)
      assert {:error, :timeout} = perform_job(EmbeddingJob, args)
      assert Repo.get!(Page, page.id).embedding_status == "error"

      use_embedding_module(Doctrans.Search.EmbeddingMock)
      assert :ok = perform_job(EmbeddingJob, args)
      assert Repo.get!(Page, page.id).embedding_status == "completed"
      assert [%Chunk{embedding_status: "completed"}] = chunks_of(page)
    end

    test "cancels a permanent failure instead of retrying it" do
      page = extracted_page("Permanent failure")
      use_embedding_module(Doctrans.Search.EmbeddingErrorStub)
      Application.put_env(:doctrans, :embedding_error_reason, {:http_error, 400})
      on_exit(fn -> Application.delete_env(:doctrans, :embedding_error_reason) end)

      assert {:cancel, {:http_error, [status: 400]}} =
               perform_job(EmbeddingJob, EmbeddingJob.page_args(page))

      assert Repo.get!(Page, page.id).embedding_status == "error"
    end

    test "leaves chunks that already carry a vector alone on a repeated attempt" do
      page = extracted_page("Already indexed")
      args = EmbeddingJob.page_args(page)
      assert :ok = perform_job(EmbeddingJob, args)
      [%Chunk{embedding: vector}] = chunks_of(page)

      # Every chunk call would fail now, so reaching :ok proves none was made.
      use_embedding_module(Doctrans.Search.EmbeddingErrorStub)
      assert :ok = perform_job(EmbeddingJob, args)
      assert [%Chunk{embedding_status: "completed", embedding: ^vector}] = chunks_of(page)
    end
  end

  defp extracted_page(text) do
    document = document_fixture()
    page_fixture(document, %{extraction_status: "completed", original_markdown: text})
  end

  defp chunks_of(page) do
    Chunk |> where([c], c.page_id == ^page.id) |> order_by([c], c.chunk_index) |> Repo.all()
  end

  defp use_embedding_module(module) do
    previous = Application.get_env(:doctrans, :embedding_module)
    Application.put_env(:doctrans, :embedding_module, module)
    on_exit(fn -> Application.put_env(:doctrans, :embedding_module, previous) end)
  end
end
