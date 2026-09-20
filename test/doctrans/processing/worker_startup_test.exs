defmodule Doctrans.Processing.WorkerStartupTest do
  # `async: false` on purpose: the sandbox is shared for a synchronous case, so a
  # worker started here can query before the test has a pid to hand the
  # connection to. That is the situation the boot-time pass is in, and the one
  # `Sandbox.allow/3` cannot be used for.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Worker

  import Doctrans.Fixtures

  setup do
    # Settled but never reconciled -- a crash between the last page write and
    # the document update. The last phase of the recovery pass is the only thing
    # that moves this row, and it queues no job while doing so, so an enabled
    # worker has to walk the whole pass to change anything here.
    document = document_fixture(%{status: "processing", total_pages: 1})

    document
    |> completed_page_fixture()
    |> Ecto.Changeset.change(embedding_status: "completed")
    |> Repo.update!()

    :ok = Topics.subscribe_document(document.id)

    %{document: document}
  end

  describe "init/1" do
    test "an enabled worker recovers on its own, from the schedule it sets in init",
         %{document: document} do
      start_worker!(startup_recovery: true, startup_delay_ms: 0, batch_interval_ms: 0)

      assert_receive {:document_updated, %Documents.Document{status: "completed"} = recovered},
                     5_000

      assert recovered.id == document.id
      assert Documents.get_document!(document.id).status == "completed"
    end

    test "a disabled worker schedules nothing and leaves the row where it was",
         %{document: document} do
      start_worker!(startup_recovery: false, startup_delay_ms: 0, batch_interval_ms: 0)

      # The case above reconciles the same row with the same delays, so this
      # window is long enough for the absence to mean something.
      refute_receive {:document_updated, _}, 500
      assert Documents.get_document!(document.id).status == "processing"
    end

    test "the suite's own configuration is the disabled one", %{document: document} do
      # No `:startup_recovery` here, so this instance reads what every worker in
      # the suite reads. `config/test.exs` turning the pass off is what keeps the
      # application's worker from querying seconds later, with the test that was
      # running when its timer started long gone and no sandbox owner left.
      start_worker!(startup_delay_ms: 0, batch_interval_ms: 0)

      refute_receive {:document_updated, _}, 500
      assert Documents.get_document!(document.id).status == "processing"
    end
  end

  defp start_worker!(opts) do
    start_supervised!(
      %{id: :worker_under_test, start: {GenServer, :start_link, [Worker, opts]}},
      restart: :temporary
    )
  end
end
