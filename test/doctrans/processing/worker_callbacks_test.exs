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

  describe "handle_info/2" do
    test "the final recovery batch settles the document it reconciles", %{worker: worker} do
      # A crash between the last page write and the document update leaves this
      # behind: every page settled, the document still "processing".
      document = document_fixture(%{status: "processing", total_pages: 1})
      completed_page_fixture(document)

      send(worker, {:recover_batch, {:completion, nil}})

      # Answered only after the batch message ahead of it in the mailbox.
      assert %{batch_interval_ms: _} = :sys.get_state(worker)
      assert Documents.get_document!(document.id).status == "completed"

      # The phase queues no work, and the batch the worker just ran was the last
      # phase and returned :done, so it scheduled no follow-up to land after
      # this test ends.
      assert Repo.aggregate(Oban.Job, :count) == 0
      assert StartupRecovery.run_batch({:completion, nil}) == :done
    end

    test "ignores an unexpected message and keeps answering", %{worker: worker} do
      send(worker, {:unexpected, :message})

      # The message is handled before the call behind it, so a crash on the
      # unmatched message would surface as an exit here rather than a reply.
      assert %{batch_interval_ms: _} = :sys.get_state(worker)
      assert Process.alive?(worker)
    end
  end
end
