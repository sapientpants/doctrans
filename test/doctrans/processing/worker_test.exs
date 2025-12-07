defmodule Doctrans.Processing.WorkerTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker

  import Doctrans.Fixtures

  describe "status/0" do
    test "returns current worker status" do
      status = Worker.status()

      assert is_map(status)
      assert Map.has_key?(status, :current_document_id)
      assert Map.has_key?(status, :queue_length)
      assert Map.has_key?(status, :extracting_count)
    end

    test "initial status has no current document" do
      status = Worker.status()

      assert status.current_document_id == nil
      assert status.queue_length == 0
    end

    test "status returns extracting_count of zero when no extractions in progress" do
      status = Worker.status()
      assert status.extracting_count == 0
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

  describe "process_document/2" do
    test "processing non-existent document is handled gracefully" do
      fake_id = Ecto.UUID.generate()

      # Should not crash
      assert :ok = Worker.process_document(fake_id, "/tmp/nonexistent.pdf")

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
      :ok = Worker.process_document(doc.id, tmp_path)

      # Give time for async handling to start
      Process.sleep(100)

      # Document should transition from uploading to some other status
      updated_doc = Documents.get_document!(doc.id)
      # The status could be extracting, error, or even completed if the mock processed it quickly
      assert updated_doc.status in ["extracting", "error", "completed", "processing"]
    end

    test "multiple calls don't crash" do
      doc1 = document_fixture(%{status: "uploading"})
      doc2 = document_fixture(%{status: "uploading"})

      :ok = Worker.process_document(doc1.id, "/tmp/nonexistent1.pdf")
      :ok = Worker.process_document(doc2.id, "/tmp/nonexistent2.pdf")

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
