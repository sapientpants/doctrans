defmodule Doctrans.Jobs.LlmProcessingJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{OpenAICrashStub, OpenAIProbe, StartupRecovery}
  alias Oban.Engines.Basic

  import Doctrans.Fixtures

  describe "enqueue_page/2" do
    test "queues the page at the ordinary priority with its generation and model" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document, %{page_number: 4})

        assert {:ok, job} = LlmProcessingJob.enqueue_page(page, extraction_model: "vision")

        assert job.queue == "llm_processing"
        assert job.priority == 2

        assert job.args == %{
                 "page_id" => page.id,
                 "page_number" => 4,
                 "generation" => page.processing_generation,
                 "extraction_model" => "vision"
               }
      end)
    end

    test "carries no model keys when the run made no choice" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document, %{page_number: 7})

        assert {:ok, job} = LlmProcessingJob.enqueue_page(page)

        assert job.args == %{
                 "page_id" => page.id,
                 "page_number" => 7,
                 "generation" => page.processing_generation
               }
      end)
    end

    test "queueing a page twice returns the job already queued for it" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture(%{status: "processing"})
        page = page_fixture(document)

        {:ok, first} = LlmProcessingJob.enqueue_page(page)
        {:ok, second} = LlmProcessingJob.enqueue_page(page)

        # Uniqueness on :page_id is what keeps one page from being processed twice.
        assert second.id == first.id
        assert second.conflict?
        assert [_only] = all_enqueued(worker: LlmProcessingJob)
      end)
    end
  end

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
          assert {:ok, page} = Pages.reset_page_for_reprocessing(page)

          # The shape `DocumentReprocessing` persists for a page-level retry.
          assert {:ok, job} =
                   page
                   |> LlmProcessingJob.page_args(
                     page.processing_generation,
                     LlmProcessingJob.model_args(@opts)
                   )
                   |> LlmProcessingJob.new(priority: 1)
                   |> Oban.insert()

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
        assert {:ok, _} = LlmProcessingJob.enqueue_page(page)
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)
        vision = OpenAI.vision_model()
        translation = OpenAI.translation_model()
        assert_received {:extract_markdown, [model: ^vision]}
        assert_received {:translate, [model: ^translation]}
      end)
    end
  end

  describe "perform/1" do
    test "handles non-existent page" do
      fake_page_id = Uniq.UUID.uuid7()

      result = perform_job(LlmProcessingJob, %{"page_id" => fake_page_id})
      assert {:error, :page_not_found} = result
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
