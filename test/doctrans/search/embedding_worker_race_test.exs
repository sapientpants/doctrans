defmodule Doctrans.Search.EmbeddingWorkerRaceTest do
  # Shared sandbox mode lets the worker task use this test's database connection.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.{Chunk, Page, Pages}
  alias Doctrans.Search.EmbeddingWorker

  import Doctrans.Fixtures

  for stage <- [:chunk, :page, :crash] do
    @stage stage
    test "regenerates corrected OCR when reprocessing interrupts #{@stage} embedding" do
      document = document_fixture()
      old_text = "Obsolete OCR #{document.id}"
      new_text = "Corrected OCR #{document.id}"
      translated_text = "Corrected translation #{document.id}"

      page =
        page_fixture(document, %{extraction_status: "completed", original_markdown: old_text})

      old_barrier = install_barrier(old_text)
      EmbeddingWorker.generate_embedding(page.id)
      assert_receive {:embedding_started, ^old_barrier, old_task}, 5_000
      old_monitor = Process.monitor(old_task)

      if @stage == :page do
        send(old_task, {:continue_embedding, old_barrier})
        assert_receive {:embedding_started, ^old_barrier, ^old_task}, 5_000
      end

      {:ok, reset} = Pages.reset_page_for_reprocessing(page)
      assert reset.content_revision > page.content_revision

      {:ok, corrected} =
        Pages.update_page_extraction(reset, %{
          original_markdown: new_text,
          extraction_status: "completed"
        })

      assert corrected.content_revision > reset.content_revision
      assert page |> chunks_for() |> Repo.all() == []
      assert Repo.get!(Page, page.id).embedding == nil

      new_barrier = install_barrier(new_text)
      # Coalesce repeated requests while retaining one regeneration.
      for _ <- 1..3, do: EmbeddingWorker.generate_embedding(page.id)
      :sys.get_state(EmbeddingWorker)

      # Translation can finish before the old embedding task releases the queued
      # regeneration. There are no chunks for the translation callback to update.
      {:ok, translated} =
        Pages.update_page_translation(corrected, %{
          translated_markdown: translated_text,
          translation_status: "completed"
        })

      EmbeddingWorker.update_chunk_translations(translated)

      reason =
        if @stage == :crash do
          Process.exit(old_task, :kill)
          :killed
        else
          send(old_task, {:continue_embedding, old_barrier})
          :normal
        end

      assert_receive {:DOWN, ^old_monitor, :process, ^old_task, ^reason}, 5_000
      assert_receive {:embedding_started, ^new_barrier, new_task}, 5_000
      new_monitor = Process.monitor(new_task)

      current = Repo.get!(Page, page.id)
      assert current.embedding_status == "processing"
      assert current.embedding == nil

      assert [%Chunk{content: ^new_text, embedding: nil}] =
               page |> chunks_for() |> Repo.all()

      send(new_task, {:continue_embedding, new_barrier})
      assert_receive {:embedding_started, ^new_barrier, ^new_task}, 5_000
      send(new_task, {:continue_embedding, new_barrier})
      assert_receive {:DOWN, ^new_monitor, :process, ^new_task, :normal}, 5_000

      completed = Repo.get!(Page, page.id)
      assert completed.original_markdown == new_text
      assert completed.embedding_status == "completed"
      assert completed.embedding != nil

      assert [%Chunk{content: ^new_text, embedding_status: "completed", embedding: vector}] =
               page |> chunks_for() |> Repo.all()

      assert vector != nil

      assert {:ok, [result]} =
               Doctrans.Search.search_by_embedding(document.id, completed.embedding)

      assert result.original_markdown == new_text
      assert result.translated_markdown == translated_text
      refute_receive {:embedding_started, ^new_barrier, _}, 50
    end
  end

  test "content changes invalidate completed chunks and page vectors atomically" do
    document = document_fixture()
    page = page_fixture(document, %{extraction_status: "completed", original_markdown: "Old OCR"})
    vector = Pgvector.new(List.duplicate(0.1, 1024))

    Repo.update!(
      Page.embedding_changeset(page, %{embedding: vector, embedding_status: "completed"})
    )

    EmbeddingWorker.recreate_chunks(page.id)

    # A bulk update also advances the revision and removes obsolete search data.
    Page
    |> where([p], p.id == ^page.id)
    |> Repo.update_all(set: [original_markdown: "New OCR"])

    current = Repo.get!(Page, page.id)
    assert current.content_revision > page.content_revision
    assert current.embedding == nil
    assert current.embedding_status == "pending"
    refute page |> chunks_for() |> Repo.exists?()
  end

  defp chunks_for(page), do: from(c in Chunk, where: c.page_id == ^page.id)

  defp install_barrier(text) do
    barrier = make_ref()
    previous = Application.get_env(:doctrans, :embedding_stub_barrier)
    Application.put_env(:doctrans, :embedding_stub_barrier, {text, self(), barrier})

    on_exit(fn ->
      if previous do
        Application.put_env(:doctrans, :embedding_stub_barrier, previous)
      else
        Application.delete_env(:doctrans, :embedding_stub_barrier)
      end
    end)

    barrier
  end

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
