defmodule Doctrans.Processing.WorkerTest do
  # The application's Worker owns the registered name and already has a startup
  # recovery pass in flight, so these cases drive an unnamed instance of their
  # own: the GenServer callbacks are then exercised against a mailbox nothing
  # else writes to, and the instance is stopped with the test. The boot-time
  # pass itself, which a test cannot hand a sandbox connection to in time, is
  # covered by `worker_startup_test.exs`.
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Processing.{StartupRecovery, Worker}
  alias Ecto.Adapters.SQL.Sandbox

  import Doctrans.Fixtures

  @moduletag :postgres

  setup do
    # `config/test.exs` leaves the boot-time pass off, so this instance only
    # runs what the test sends it.
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

  describe "recover_now/1" do
    test "runs every phase and returns only once the pass is done", %{worker: worker} do
      # The suite runs Oban `testing: :inline`, which executes each job at insert;
      # manual mode leaves whatever the pass queues in the table to be counted.
      Oban.Testing.with_testing_mode(:manual, fn ->
        # A crash between the last page write and the document update leaves
        # this behind: the page settled, the document still "processing". Only
        # the last phase of the pass resolves it, so a reply that arrives before
        # the pass reached that phase would leave the document as it was.
        document = document_fixture(%{status: "processing", total_pages: 1})

        document
        |> completed_page_fixture()
        |> Ecto.Changeset.change(embedding_status: "completed")
        |> Repo.update!()

        assert Worker.recover_now(worker) == :ok

        assert Documents.get_document!(document.id).status == "completed"

        # The phases ahead of it had nothing to resume, and the last one queues
        # nothing by design.
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end
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
