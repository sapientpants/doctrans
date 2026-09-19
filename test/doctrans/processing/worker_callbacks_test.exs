defmodule Doctrans.Processing.WorkerCallbacksTest do
  # The application's Worker owns the registered name and already has a startup
  # recovery pass in flight, so these cases drive an unnamed instance of their
  # own: the GenServer callbacks are then exercised against a mailbox nothing
  # else writes to, and the instance is stopped with the test.
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Processing.{StartupRecovery, Worker}
  alias Ecto.Adapters.SQL.Sandbox

  import Doctrans.Fixtures

  @moduletag :postgres

  setup do
    worker =
      start_supervised!(
        %{
          id: :worker_under_test,
          start: {GenServer, :start_link, [Worker, []]}
        },
        restart: :temporary
      )

    # The instance reads Oban and the document tables from its own process.
    Sandbox.allow(Repo, self(), worker)

    %{worker: worker}
  end

  describe "handle_call/3" do
    test "answers :status with the counts of the jobs actually queued", %{worker: worker} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        document = document_fixture()
        first = page_fixture(document, %{page_number: 1})
        second = page_fixture(document, %{page_number: 2})
        {:ok, _extraction} = Worker.process_document(document.id, "/tmp/document.pdf")
        {:ok, _processing} = Worker.queue_page(first.id, page_number: 1)
        {:ok, _reprocessing} = Worker.queue_page_reprocess(second.id, translation_model: "custom")

        assert GenServer.call(worker, :status) == %{
                 pdf_extraction: 1,
                 llm_processing: 2,
                 embedding_generation: 0,
                 health_check: 0
               }
      end)
    end
  end

  describe "handle_cast/2" do
    test "ignores an unexpected cast and keeps answering", %{worker: worker} do
      :ok = GenServer.cast(worker, {:unexpected, :message})

      # The cast is handled before the call behind it, so a crash on the
      # unmatched message would surface as an exit here rather than a reply.
      assert GenServer.call(worker, :status) == %{
               pdf_extraction: 0,
               llm_processing: 0,
               embedding_generation: 0,
               health_check: 0
             }
    end
  end

  describe "handle_info/2" do
    test "the final recovery batch settles the document it reconciles", %{worker: worker} do
      # A crash between the last page write and the document update leaves this
      # behind: every page settled, the document still "processing".
      document = document_fixture(%{status: "processing", total_pages: 1})
      completed_page_fixture(document)

      send(worker, {:recover_batch, {:completion, nil}})

      # Answered only after the batch message ahead of it in the mailbox, and
      # the zero counts are the phase's other promise: it queues no work.
      assert %{llm_processing: 0, pdf_extraction: 0} = GenServer.call(worker, :status)
      assert Documents.get_document!(document.id).status == "completed"

      # The batch the worker just ran was the last phase and returned :done, so
      # it scheduled no follow-up to land after this test ends.
      assert StartupRecovery.run_batch({:completion, nil}) == :done
    end

    test "ignores an unexpected message and keeps answering", %{worker: worker} do
      send(worker, {:unexpected, :message})

      assert GenServer.call(worker, :status) == %{
               pdf_extraction: 0,
               llm_processing: 0,
               embedding_generation: 0,
               health_check: 0
             }
    end
  end
end
