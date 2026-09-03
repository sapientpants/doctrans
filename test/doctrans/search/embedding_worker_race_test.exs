defmodule Doctrans.Search.EmbeddingWorkerRaceTest do
  # async: false puts the sandbox in {:shared, self()} mode, so the background
  # worker task sees the same (uncommitted) data the test does.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.Page
  alias Doctrans.Search.EmbeddingWorker

  import Doctrans.Fixtures

  describe "embedding task vs concurrent deletion" do
    test "completes cleanly when the page is deleted mid-embedding" do
      counter = :counters.new(1, [])

      :telemetry.attach(
        "embedding-crash-race",
        [:doctrans, :embedding, :crashed],
        fn _, _, _, _ -> :counters.add(counter, 1, 1) end,
        %{}
      )

      on_exit(fn -> :telemetry.detach("embedding-crash-race") end)

      Application.put_env(:doctrans, :embedding_stub_delay_ms, 300)
      on_exit(fn -> Application.delete_env(:doctrans, :embedding_stub_delay_ms) end)

      document = document_fixture()
      page = completed_page_fixture(document)

      :ok = EmbeddingWorker.generate_embedding(page.id)

      # Let the task enter the (artificially delayed) embedding call, then
      # delete the page so its chunks disappear under the running task.
      Process.sleep(150)
      Repo.delete!(page)

      # Give the task time to finish (it makes two delayed embedding calls)
      Process.sleep(1_000)

      assert :counters.get(counter, 1) == 0
      assert Repo.get(Page, page.id) == nil
    end
  end
end
