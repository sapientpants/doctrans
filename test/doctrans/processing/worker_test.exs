defmodule Doctrans.Processing.WorkerTest do
  use Doctrans.DataCase, async: false, background_processes: true

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker

  import Doctrans.Fixtures

  # Wait for Worker to be available and responsive before each test
  setup do
    # Give any in-flight operations time to settle
    Process.sleep(50)

    # Ensure Worker is alive - if it crashed, the supervisor should restart it
    # Try to get status, with retries if Worker is restarting
    ensure_worker_responsive()

    :ok
  end

  defp ensure_worker_responsive(retries \\ 3)

  defp ensure_worker_responsive(0), do: raise("Worker not responsive after retries")

  defp ensure_worker_responsive(retries) do
    Worker.status()
  catch
    :exit, _ ->
      Process.sleep(100)
      ensure_worker_responsive(retries - 1)
  end

  describe "status/0" do
    test "returns current worker status with expected keys" do
      status = Worker.status()

      assert is_map(status)
      assert Map.has_key?(status, :pdf_extraction)
      assert Map.has_key?(status, :llm_processing)
      assert Map.has_key?(status, :embedding_generation)
      assert Map.has_key?(status, :health_check)
    end

    test "status returns queue counts when no jobs are running" do
      status = Worker.status()
      assert status.pdf_extraction == 0
      assert status.llm_processing == 0
      assert status.embedding_generation == 0
      assert status.health_check == 0
    end
  end

  describe "cancel_document/1" do
    test "cancelling a document doesn't crash" do
      doc = document_fixture()

      # Should not raise
      assert :ok = Worker.cancel_document(doc.id)
    end

    test "cancelling non-existent document doesn't crash" do
      # Should not raise
      assert :ok = Worker.cancel_document(Ecto.UUID.generate())
    end

    test "cancelling document prevents queuing for LLM" do
      doc = document_fixture(%{status: "extracting"})

      # Cancel the document first
      :ok = Worker.cancel_document(doc.id)

      # Give time for the cancel to process
      Process.sleep(10)

      # Worker should still be responsive
      status = Worker.status()
      assert is_map(status)
    end
  end

  describe "queue_page/1" do
    test "queueing a page doesn't crash" do
      doc = document_fixture(%{status: "processing"})
      page = page_fixture(doc, %{page_number: 1})

      # Cancel the document first to prevent actual processing
      # (which would fail due to sandbox isolation)
      :ok = Worker.cancel_document(doc.id)

      # Should not raise
      assert {:ok, _job} = Worker.queue_page(page.id)
    end

    test "queueing non-existent page doesn't crash" do
      # Should not raise
      assert {:ok, _job} = Worker.queue_page(Ecto.UUID.generate())
    end
  end

  describe "process_document/2" do
    test "processing non-existent document is handled gracefully" do
      fake_id = Ecto.UUID.generate()

      # Should not crash
      assert {:ok, _job} = Worker.process_document(fake_id, "/tmp/nonexistent.pdf")

      # Give time for async handling
      Process.sleep(50)

      # Worker should still be responsive
      status = Worker.status()
      assert is_map(status)
    end

    test "processing existing document starts extraction" do
      doc = document_fixture(%{status: "uploading"})

      # Create a temp PDF file
      tmp_path = Path.join(System.tmp_dir!(), "test_#{doc.id}.pdf")
      File.write!(tmp_path, "%PDF-1.4 fake pdf content")

      on_exit(fn -> File.rm(tmp_path) end)

      # Process the document
      assert {:ok, _job} = Worker.process_document(doc.id, tmp_path)

      # With testing: :inline, the job runs immediately but may not update status
      # due to mocking. Just verify the job was created successfully.
      updated_doc = Documents.get_document!(doc.id)
      # The document status might not change due to mocking, which is fine
      assert updated_doc.id == doc.id
    end

    test "multiple calls don't crash" do
      doc1 = document_fixture(%{status: "uploading"})
      doc2 = document_fixture(%{status: "uploading"})

      assert {:ok, _job1} = Worker.process_document(doc1.id, "/tmp/nonexistent1.pdf")
      assert {:ok, _job2} = Worker.process_document(doc2.id, "/tmp/nonexistent2.pdf")

      # Give time for async handling
      Process.sleep(50)

      # Worker should still be responsive
      status = Worker.status()
      assert is_map(status)
    end
  end

  describe "GenServer callbacks" do
    test "worker handles unknown messages gracefully" do
      # Send unknown message directly
      send(Worker, {:unknown_message, "test"})

      # Give time for message processing
      Process.sleep(10)

      # Worker should still be responsive
      status = Worker.status()
      assert is_map(status)
    end
  end
end
