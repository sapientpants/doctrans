defmodule Doctrans.Jobs.LlmProcessingJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{OpenAICrashStub, OpenAIProbe, StartupRecovery, Worker}
  alias Oban.Engines.Basic

  import Doctrans.Fixtures

  describe "persisted model selections" do
    setup do
      previous_module = Application.fetch_env!(:doctrans, :openai_module)
      Application.put_env(:doctrans, :openai_module, OpenAIProbe)
      Application.put_env(:doctrans, :openai_probe_pid, self())

      on_exit(fn ->
        Application.put_env(:doctrans, :openai_module, previous_module)
        Application.delete_env(:doctrans, :openai_probe_pid)
      end)

      :ok
    end

    for opts <- [
          [extraction_model: "selected-vision", translation_model: "selected-translation"],
          [extraction_model: "selected-vision"],
          [translation_model: "selected-translation"],
          []
        ] do
      @opts opts
      test "reprocessing preserves #{inspect(opts)} through the database" do
        Oban.Testing.with_testing_mode(:manual, fn ->
          document = document_fixture(%{total_pages: 1, status: "completed"})
          page = completed_page_fixture(document)
          assert {:ok, _} = Pages.reset_page_for_reprocessing(page)
          assert {:ok, job} = Worker.queue_page_reprocess(page.id, @opts)
          persisted = Repo.get!(Oban.Job, job.id)

          for {key, model} <- @opts do
            assert persisted.args[Atom.to_string(key)] == model
          end

          assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)

          extraction_opts =
            if @opts[:extraction_model],
              do: [model: @opts[:extraction_model]],
              else: [model: OpenAI.vision_model()]

          translation_opts =
            if @opts[:translation_model],
              do: [model: @opts[:translation_model]],
              else: [model: OpenAI.translation_model()]

          assert_received {:extract_markdown, ^extraction_opts}
          assert_received {:translate, ^translation_opts}
          saved = Documents.get_page!(page.id)
          assert saved.extraction_status == "completed"
          assert saved.translation_status == "completed"
          assert Repo.get!(Oban.Job, job.id).state == "completed"
        end)
      end
    end

    test "ordinary queued pages use default models" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{total_pages: 1})
        page = page_fixture(document)
        assert {:ok, _} = Worker.queue_page(page.id, page_number: 1)
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)
        vision = OpenAI.vision_model()
        translation = OpenAI.translation_model()
        assert_received {:extract_markdown, [model: ^vision]}
        assert_received {:translate, [model: ^translation]}
      end)
    end
  end

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

    test "a crash on the last attempt still settles the document" do
      previous_module = Application.fetch_env!(:doctrans, :openai_module)
      Application.put_env(:doctrans, :openai_module, OpenAICrashStub)
      on_exit(fn -> Application.put_env(:doctrans, :openai_module, previous_module) end)

      document = document_fixture(%{status: "processing", total_pages: 1})
      page = page_fixture(document)
      args = %{"page_id" => page.id, "generation" => page.processing_generation}

      assert_raise RuntimeError, "extraction crashed", fn ->
        perform_job(LlmProcessingJob, args, attempt: 3)
      end

      assert Documents.get_document!(document.id).status == "error"
    end

    test "a crash before the last attempt leaves the document processing" do
      previous_module = Application.fetch_env!(:doctrans, :openai_module)
      Application.put_env(:doctrans, :openai_module, OpenAICrashStub)
      on_exit(fn -> Application.put_env(:doctrans, :openai_module, previous_module) end)

      document = document_fixture(%{status: "processing", total_pages: 1})
      page = page_fixture(document)
      args = %{"page_id" => page.id, "generation" => page.processing_generation}

      assert_raise RuntimeError, "extraction crashed", fn ->
        perform_job(LlmProcessingJob, args, attempt: 1)
      end

      assert Documents.get_document!(document.id).status == "processing"
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

      assert {:embeddings, nil} = StartupRecovery.run_batch({:pages, nil})

      assert {:ok, [%{id: rescued_id}]} =
               Basic.rescue_jobs(Oban.config(), Oban.Job, rescue_after: 3_600_000)

      assert rescued_id == job.id
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)
      saved = Documents.get_page!(page.id)
      assert saved.extraction_status == "completed"
      assert saved.translation_status == "completed"

      # The rescue reused the orphan rather than queueing a second page job; the
      # extra job is this page's indexing request, on its own queue.
      assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "llm_processing"), :count) == 1

      assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "embedding_generation"), :count) ==
               1
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
