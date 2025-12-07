defmodule Doctrans.Documents.SweeperTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Sweeper

  import Doctrans.Fixtures

  setup do
    # Create the documents directory for testing
    uploads_dir = Documents.uploads_dir()
    documents_dir = Path.join(uploads_dir, "documents")
    File.mkdir_p!(documents_dir)

    on_exit(fn ->
      # Clean up any test directories we created
      File.rm_rf(documents_dir)
    end)

    %{documents_dir: documents_dir}
  end

  describe "find_orphaned_directories/1" do
    test "returns empty list when no directories exist", %{documents_dir: documents_dir} do
      # Remove any existing directories
      File.rm_rf!(documents_dir)
      File.mkdir_p!(documents_dir)

      assert Sweeper.find_orphaned_directories(grace_period_hours: 0) == []
    end

    test "returns empty list when all directories have database records", %{
      documents_dir: documents_dir
    } do
      doc = document_fixture()
      doc_dir = Path.join(documents_dir, doc.id)
      File.mkdir_p!(doc_dir)

      orphaned = Sweeper.find_orphaned_directories(grace_period_hours: 0)
      assert orphaned == []
    end

    test "finds directories without database records when old enough", %{
      documents_dir: documents_dir
    } do
      # Create a directory with a fake UUID that doesn't exist in DB
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      # With grace_period_hours: 0, the directory is immediately considered old enough
      orphaned = Sweeper.find_orphaned_directories(grace_period_hours: 0)
      assert orphan_dir in orphaned
    end

    test "excludes directories that have database records", %{documents_dir: documents_dir} do
      # Create a document and its directory
      doc = document_fixture()
      doc_dir = Path.join(documents_dir, doc.id)
      File.mkdir_p!(doc_dir)

      # Create an orphan directory
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      orphaned = Sweeper.find_orphaned_directories(grace_period_hours: 0)
      assert orphan_dir in orphaned
      refute doc_dir in orphaned
    end

    test "ignores files, only returns directories", %{documents_dir: documents_dir} do
      # Create a file (not a directory)
      file_path = Path.join(documents_dir, "some_file.txt")
      File.write!(file_path, "test")

      orphaned = Sweeper.find_orphaned_directories(grace_period_hours: 0)
      refute file_path in orphaned
    end

    test "respects grace_period_hours option", %{documents_dir: documents_dir} do
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      # Just created, so not old enough with 24 hour threshold
      orphaned = Sweeper.find_orphaned_directories(grace_period_hours: 24)
      refute orphan_dir in orphaned

      # But with 0 hours, it should be found
      orphaned = Sweeper.find_orphaned_directories(grace_period_hours: 0)
      assert orphan_dir in orphaned
    end
  end

  describe "sweep/1" do
    test "removes orphaned directories", %{documents_dir: documents_dir} do
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      # Create a file inside to verify rm_rf works
      File.write!(Path.join(orphan_dir, "test.txt"), "content")

      assert {:ok, count} = Sweeper.sweep(grace_period_hours: 0)
      assert count >= 1
      refute File.exists?(orphan_dir)
    end

    test "does not remove directories with database records", %{documents_dir: documents_dir} do
      doc = document_fixture()
      doc_dir = Path.join(documents_dir, doc.id)
      File.mkdir_p!(doc_dir)

      assert {:ok, _} = Sweeper.sweep(grace_period_hours: 0)
      assert File.exists?(doc_dir)
    end

    test "dry_run option does not delete", %{documents_dir: documents_dir} do
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      assert {:ok, 1} = Sweeper.sweep(dry_run: true, grace_period_hours: 0)
      assert File.exists?(orphan_dir)
    end

    test "returns count of removed directories", %{documents_dir: documents_dir} do
      # Count existing orphaned directories first
      initial_orphaned = length(Sweeper.find_orphaned_directories(grace_period_hours: 0))

      # Create multiple orphan directories
      for _ <- 1..3 do
        fake_uuid = Ecto.UUID.generate()
        File.mkdir_p!(Path.join(documents_dir, fake_uuid))
      end

      assert {:ok, count} = Sweeper.sweep(grace_period_hours: 0)
      assert count == initial_orphaned + 3
    end

    test "does not remove recent directories when grace_period_hours is set", %{
      documents_dir: documents_dir
    } do
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      # With default 24 hour threshold, recently created dir should not be removed
      assert {:ok, 0} = Sweeper.sweep(grace_period_hours: 24)
      assert File.exists?(orphan_dir)
    end
  end
end
