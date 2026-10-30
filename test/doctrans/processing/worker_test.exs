defmodule Doctrans.Processing.WorkerTest do
  # `recover_now/1` reaches the GenServer, so this starts an unnamed instance of
  # its own and hands it the sandbox connection, the way
  # `worker_callbacks_test.exs` does.
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker
  alias Ecto.Adapters.SQL.Sandbox

  import Doctrans.Fixtures

  describe "recover_now/1" do
    setup do
      # The application's worker owns the registered name, and `config/test.exs`
      # leaves its boot-time pass off; this instance is driven on demand and
      # stopped with the test.
      worker =
        start_supervised!(
          %{id: :worker_under_test, start: {GenServer, :start_link, [Worker, []]}},
          restart: :temporary
        )

      Sandbox.allow(Repo, self(), worker)

      %{worker: worker}
    end

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
end
