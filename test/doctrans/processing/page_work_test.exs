defmodule Doctrans.Processing.PageWorkTest do
  @moduledoc """
  `PageWork.queue/3` at its interface: the three kinds of request, what each
  writes to the queue, and the three answers a request can get.

  The Oban rows are checked here and nowhere else: this is the one module that
  writes them, so the tests of Extraction, Reprocessing and Recovery can assert
  on its answer and on the page instead.
  """
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents
  alias Doctrans.Documents.{PageLifecycle, Topics}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{OpenAIProbe, PageWork}

  setup do
    document = document_fixture(%{status: "processing", total_pages: 1})
    %{document: document, page: page_fixture(document, %{page_number: 4})}
  end

  # A run records the models it was started with on the document; the fixture
  # starts its run with the defaults, so a document with chosen models is
  # written here the way `Lifecycle.requeue/2` would have written it.
  defp choose_models(document, extraction, translation) do
    document
    |> Ecto.Changeset.change(extraction_model: extraction, translation_model: translation)
    |> Repo.update!()
  end

  describe "queue/3 as :fresh" do
    test "queues the page at the ordinary priority with its generation and the run's models",
         %{document: document, page: page} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :queued} = PageWork.queue(page, document, as: :fresh)

        assert [job] = all_enqueued(worker: LlmProcessingJob)
        assert job.queue == "llm_processing"
        assert job.priority == 2
        assert job.meta == %{}

        assert job.args == %{
                 "page_id" => page.id,
                 "page_number" => 4,
                 "generation" => page.processing_generation,
                 "extraction_model" => document.extraction_model,
                 "translation_model" => document.translation_model
               }
      end)
    end

    test "carries no model a run did not record", %{document: document, page: page} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = choose_models(document, nil, nil)
        assert {:ok, :queued} = PageWork.queue(page, document, as: :fresh)

        assert [job] = all_enqueued(worker: LlmProcessingJob)
        refute Map.has_key?(job.args, "extraction_model")
        refute Map.has_key?(job.args, "translation_model")
      end)
    end
  end

  describe "queue/3 as :requested" do
    test "goes ahead of fresh pages and carries the models the page requested", %{
      document: document,
      page: page
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, reset} = PageLifecycle.reset(page, %{extraction_model: "chosen-vision"})

        assert {:ok, :queued} = PageWork.queue(reset, document, as: :requested)

        assert [job] = all_enqueued(worker: LlmProcessingJob)
        assert job.priority == 1
        assert job.meta == %{}
        assert job.args["generation"] == reset.processing_generation
        assert job.args["extraction_model"] == "chosen-vision"
        # A stage the user chose nothing for keeps the run's model.
        assert job.args["translation_model"] == document.translation_model
      end)
    end

    test "a requested model wins over the document's", %{document: document, page: page} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = choose_models(document, "doc-vision", "doc-text")
        {:ok, reset} = PageLifecycle.reset(page, %{translation_model: "chosen-text"})

        assert {:ok, :queued} = PageWork.queue(reset, document, as: :requested)

        assert [job] = all_enqueued(worker: LlmProcessingJob)
        assert job.args["extraction_model"] == "doc-vision"
        assert job.args["translation_model"] == "chosen-text"
      end)
    end
  end

  describe "queue/3 as :recovered" do
    test "queues at the ordinary priority and marks the job as recovered", %{
      document: document,
      page: page
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :queued} = PageWork.queue(page, document, as: :recovered)

        assert [job] = all_enqueued(worker: LlmProcessingJob)
        assert job.priority == 2
        assert job.meta == %{"recovered" => true}
        assert job.args["page_id"] == page.id
      end)
    end

    test "resumes the stages the job will redo and keeps the one that completed", %{
      document: document
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        page =
          page_fixture(document, %{
            page_number: 9,
            extraction_status: "completed",
            original_markdown: "Saved text",
            translation_status: "processing"
          })

        Topics.subscribe_document(document.id)
        assert {:ok, :queued} = PageWork.queue(page, document, as: :recovered)

        resumed = Documents.get_page!(page.id)
        assert resumed.extraction_status == "completed"
        assert resumed.original_markdown == "Saved text"
        assert resumed.translation_status == "pending"
        assert_received {:page_updated, %{id: id}} when id == page.id
      end)
    end

    test "a page another job owns keeps its stages", %{document: document} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        page = page_fixture(document, %{page_number: 9, extraction_status: "processing"})
        assert {:ok, :queued} = PageWork.queue(page, document, as: :fresh)

        assert {:ok, :owned} = PageWork.queue(page, document, as: :recovered)
        assert Documents.get_page!(page.id).extraction_status == "processing"
      end)
    end
  end

  describe "queue/3 answers" do
    test "a page an active job already holds is owned, whatever the kind", %{
      document: document,
      page: page
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :queued} = PageWork.queue(page, document, as: :fresh)

        # Uniqueness on the page is what keeps one page from being processed twice.
        assert {:ok, :owned} = PageWork.queue(page, document, as: :fresh)
        assert {:ok, :owned} = PageWork.queue(page, document, as: :requested)
        assert {:ok, :owned} = PageWork.queue(page, document, as: :recovered)
        assert [_only] = all_enqueued(worker: LlmProcessingJob)
      end)
    end

    test "a page whose content stages are both complete owes nothing", %{document: document} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        page = completed_page_fixture(document, %{page_number: 9})

        assert {:ok, :not_owed} = PageWork.queue(page, document, as: :fresh)
        assert {:ok, :not_owed} = PageWork.queue(page, document, as: :recovered)
        assert all_enqueued(worker: LlmProcessingJob) == []
      end)
    end

    test "a page with one stage still owed is queued", %{document: document} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        page =
          page_fixture(document, %{
            page_number: 9,
            extraction_status: "completed",
            original_markdown: "Extracted",
            translation_status: "error"
          })

        assert {:ok, :queued} = PageWork.queue(page, document, as: :fresh)
      end)
    end
  end

  # The job's own `perform/1` reads the models back out of the row, so a model
  # a page carries through the queue is the one its attempt calls.
  describe "the queued models reach the attempt" do
    setup do
      OpenAIProbe.install()
      :ok
    end

    for choices <- [
          %{extraction_model: "selected-vision", translation_model: "selected-translation"},
          %{extraction_model: "selected-vision"},
          %{translation_model: "selected-translation"},
          %{}
        ] do
      @choices choices
      test "a page reset with #{inspect(choices)} is processed with them", %{document: document} do
        Oban.Testing.with_testing_mode(:manual, fn ->
          page = completed_page_fixture(document, %{page_number: 1})
          {:ok, reset} = PageLifecycle.reset(page, @choices)

          assert {:ok, :queued} = PageWork.queue(reset, document, as: :requested)
          assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)

          extraction = [model: @choices[:extraction_model] || OpenAI.vision_model()]
          translation = [model: @choices[:translation_model] || OpenAI.translation_model()]
          assert_received {:extract_markdown, ^extraction}
          assert_received {:translate, ^translation}

          saved = Documents.get_page!(page.id)
          assert saved.extraction_status == "completed"
          assert saved.translation_status == "completed"
        end)
      end
    end

    test "a fresh page without choices uses the defaults", %{document: document, page: page} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :queued} = PageWork.queue(page, document, as: :fresh)
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :llm_processing)

        vision = OpenAI.vision_model()
        translation = OpenAI.translation_model()
        assert_received {:extract_markdown, [model: ^vision]}
        assert_received {:translate, [model: ^translation]}
      end)
    end
  end
end
