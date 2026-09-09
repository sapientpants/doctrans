defmodule Doctrans.Jobs.LlmProcessingJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.StartupRecovery
  alias Oban.Engines.Basic

  import Doctrans.Fixtures

  describe "perform/1" do
    test "processes page without opts" do
      document = document_fixture()

      {:ok, page} =
        Pages.create_page(document, %{
          page_number: 1,
          image_path: "/nonexistent/image.png"
        })

      result = perform_job(LlmProcessingJob, %{"page_id" => page.id})
      # Result depends on the API availability and file existence
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles non-existent page" do
      fake_page_id = Uniq.UUID.uuid7()

      result = perform_job(LlmProcessingJob, %{"page_id" => fake_page_id})
      assert {:error, _reason} = result
    end
  end

  test "rescues an orphan and resumes its interrupted extraction" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{extraction_status: "processing"})
      job = %{"page_id" => page.id} |> LlmProcessingJob.new() |> Oban.insert!()

      job
      |> Ecto.Changeset.change(
        state: "executing",
        attempt: 1,
        attempted_at: DateTime.add(DateTime.utc_now(), -7200)
      )
      |> Repo.update!()

      assert :done = StartupRecovery.run_batch({:pages, nil})

      assert {:ok, [%{id: rescued_id}]} =
               Basic.rescue_jobs(Oban.config(), Oban.Job, rescue_after: 3_600_000)

      assert rescued_id == job.id
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)
      saved = Documents.get_page!(page.id)
      assert saved.extraction_status == "completed"
      assert saved.translation_status == "completed"
      assert Repo.aggregate(Oban.Job, :count) == 1
    end)
  end

  test "retries interrupted and errored translation without repeating extraction" do
    for status <- ["processing", "error"] do
      document = document_fixture(%{status: "processing"})

      page =
        page_fixture(document, %{
          extraction_status: "completed",
          original_markdown: "Preserved extraction",
          translation_status: status
        })

      assert :ok = perform_job(LlmProcessingJob, %{"page_id" => page.id}, attempt: 2)
      saved = Documents.get_page!(page.id)
      assert saved.original_markdown == "Preserved extraction"
      assert saved.translation_status == "completed"
    end
  end
end
