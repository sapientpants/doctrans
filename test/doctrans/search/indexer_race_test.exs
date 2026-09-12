defmodule Doctrans.Search.IndexerRaceTest do
  # Shared sandbox mode lets the indexing task use this test's database connection.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.{Chunk, Page, Pages}
  alias Doctrans.Search.Indexer

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
      old_run = index_async(page)
      assert_receive {:embedding_started, ^old_barrier, old_task}, 5_000

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

      # Translation can finish before the obsolete run releases. Regenerated
      # chunks must still use only source content.
      {:ok, _translated} =
        Pages.update_page_translation(corrected, %{
          translated_markdown: translated_text,
          translation_status: "completed"
        })

      # Installing the next barrier before releasing the obsolete run lets that run
      # finish: it embeds the old text, which no longer matches the barrier.
      new_barrier = install_barrier(new_text)

      if @stage == :crash do
        Process.exit(old_task, :kill)
        assert {:exit, :killed} = Task.yield(old_run, 5_000)
      else
        send(old_task, {:continue_embedding, old_barrier})
        assert {:ok, {:cancel, :stale_page}} = Task.yield(old_run, 5_000)
      end

      # The obsolete run wrote nothing: the revision it was queued for is gone.
      superseded = Repo.get!(Page, page.id)
      assert superseded.embedding_status == "pending"
      assert superseded.embedding == nil
      assert page |> chunks_for() |> Repo.all() == []

      new_run = index_async(corrected)
      assert_receive {:embedding_started, ^new_barrier, new_task}, 5_000

      current = Repo.get!(Page, page.id)
      assert current.embedding_status == "processing"
      assert current.embedding == nil

      assert [%Chunk{content: ^new_text, embedding: nil}] = page |> chunks_for() |> Repo.all()

      send(new_task, {:continue_embedding, new_barrier})
      assert_receive {:embedding_started, ^new_barrier, ^new_task}, 5_000
      send(new_task, {:continue_embedding, new_barrier})
      assert {:ok, :ok} = Task.yield(new_run, 5_000)

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
      assert result.translated_markdown == nil
      refute_receive {:embedding_started, ^new_barrier, _}, 50
    end
  end

  test "content changes invalidate completed chunks and page vectors atomically" do
    document = document_fixture()
    page = page_fixture(document, %{extraction_status: "completed", original_markdown: "Old OCR"})

    assert :ok = Indexer.index_page(page.id)

    indexed = Repo.get!(Page, page.id)
    assert indexed.embedding_status == "completed"
    assert indexed.embedding != nil
    assert page |> chunks_for() |> Repo.exists?()

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

  # Runs one indexing attempt off the test process, so the barrier can hold it
  # mid-flight while this test changes the page underneath it.
  defp index_async(page) do
    Task.Supervisor.async_nolink(Doctrans.TaskSupervisor, fn ->
      Indexer.index_page(page.id, page.content_revision)
    end)
  end

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

  describe "indexing vs concurrent deletion" do
    test "completes cleanly when the page is deleted mid-embedding" do
      document = document_fixture()
      text = "Embedding deletion race #{document.id}"
      page = page_fixture(document, %{extraction_status: "completed", original_markdown: text})
      chunks = from c in Chunk, where: c.page_id == ^page.id
      barrier = install_barrier(text)

      run = index_async(page)

      # The first call embeds the single chunk. It stays blocked until deletion
      # has completed, regardless of scheduler speed.
      assert_receive {:embedding_started, ^barrier, task_pid}, 5_000

      try do
        assert [%Chunk{embedding_status: "processing"}] = Repo.all(chunks)

        Repo.delete!(page)
        send(task_pid, {:continue_embedding, barrier})

        # The page-level fallback must also tolerate the now-deleted page.
        assert_receive {:embedding_started, ^barrier, ^task_pid}, 5_000
        send(task_pid, {:continue_embedding, barrier})

        assert {:ok, {:cancel, :stale_page}} = Task.yield(run, 5_000)
        assert Repo.get(Page, page.id) == nil
        refute Repo.exists?(chunks)
      after
        Task.Supervisor.terminate_child(Doctrans.TaskSupervisor, task_pid)
      end
    end
  end
end
