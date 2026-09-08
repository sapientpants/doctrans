defmodule Doctrans.Search.EmbeddingWorkerRaceTest do
  # Shared sandbox mode lets the worker task use this test's database connection.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Search.EmbeddingWorker

  import Doctrans.Fixtures

  describe "embedding task vs concurrent deletion" do
    test "completes cleanly when the page is deleted mid-embedding" do
      document = document_fixture()
      text = "Embedding deletion race #{document.id}"
      page = page_fixture(document, %{extraction_status: "completed", original_markdown: text})
      chunks = from c in Chunk, where: c.page_id == ^page.id
      barrier = make_ref()
      previous_barrier = Application.get_env(:doctrans, :embedding_stub_barrier)

      Application.put_env(:doctrans, :embedding_stub_barrier, {text, self(), barrier})

      on_exit(fn ->
        if previous_barrier do
          Application.put_env(:doctrans, :embedding_stub_barrier, previous_barrier)
        else
          Application.delete_env(:doctrans, :embedding_stub_barrier)
        end
      end)

      :ok = EmbeddingWorker.generate_embedding(page.id)

      # The first call embeds the single chunk. It stays blocked until deletion
      # has completed, regardless of scheduler speed.
      assert_receive {:embedding_started, ^barrier, task_pid}, 5_000
      monitor = Process.monitor(task_pid)

      try do
        assert [%Chunk{embedding_status: "processing"}] =
                 Repo.all(chunks)

        Repo.delete!(page)
        send(task_pid, {:continue_embedding, barrier})

        # The page-level fallback must also tolerate the now-deleted page.
        assert_receive {:embedding_started, ^barrier, ^task_pid}, 5_000
        send(task_pid, {:continue_embedding, barrier})

        # Observe this task directly: crashes from unrelated pages cannot affect
        # the assertion, and the sandbox stays alive until this task has exited.
        assert_receive {:DOWN, ^monitor, :process, ^task_pid, :normal}, 5_000
        assert Repo.get(Page, page.id) == nil
        refute Repo.exists?(chunks)
      after
        Task.Supervisor.terminate_child(Doctrans.TaskSupervisor, task_pid)
        Process.demonitor(monitor, [:flush])
      end
    end
  end
end
