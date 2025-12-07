defmodule Doctrans.Documents.SweeperTest do
  use Doctrans.DataCase, async: false

  import Ecto.Query

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

  describe "find_orphaned_directories/0" do
    test "returns empty list when no directories exist", %{documents_dir: documents_dir} do
      # Remove any existing directories
      File.rm_rf!(documents_dir)
      File.mkdir_p!(documents_dir)

      assert Sweeper.find_orphaned_directories() == []
    end

    test "returns empty list when all directories have database records", %{
      documents_dir: documents_dir
    } do
      doc = document_fixture()
      doc_dir = Path.join(documents_dir, doc.id)
      File.mkdir_p!(doc_dir)

      orphaned = Sweeper.find_orphaned_directories()
      assert orphaned == []
    end

    test "finds directories without database records", %{documents_dir: documents_dir} do
      # Create a directory with a fake UUID that doesn't exist in DB
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      orphaned = Sweeper.find_orphaned_directories()
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

      orphaned = Sweeper.find_orphaned_directories()
      assert orphan_dir in orphaned
      refute doc_dir in orphaned
    end

    test "ignores files, only returns directories", %{documents_dir: documents_dir} do
      # Create a file (not a directory)
      file_path = Path.join(documents_dir, "some_file.txt")
      File.write!(file_path, "test")

      orphaned = Sweeper.find_orphaned_directories()
      refute file_path in orphaned
    end
  end

  describe "find_stale_documents/1" do
    test "returns empty list when no documents are stale" do
      _doc = document_fixture(%{status: "completed"})
      assert Sweeper.find_stale_documents() == []
    end

    test "finds documents with stale uploading status" do
      # Create a document with uploading status and old inserted_at
      doc = document_fixture(%{status: "uploading"})

      # Manually update the inserted_at to be old
      {1, _} =
        Documents.Document
        |> where([d], d.id == ^doc.id)
        |> Doctrans.Repo.update_all(
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
        )

      stale = Sweeper.find_stale_documents(max_age_hours: 24, statuses: ["uploading"])
      stale_ids = Enum.map(stale, & &1.id)
      assert doc.id in stale_ids
    end

    test "finds documents with stale extracting status" do
      doc = document_fixture(%{status: "extracting"})

      {1, _} =
        Documents.Document
        |> where([d], d.id == ^doc.id)
        |> Doctrans.Repo.update_all(
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
        )

      stale = Sweeper.find_stale_documents(max_age_hours: 24, statuses: ["extracting"])
      stale_ids = Enum.map(stale, & &1.id)
      assert doc.id in stale_ids
    end

    test "does not find recent documents" do
      _doc = document_fixture(%{status: "uploading"})

      stale = Sweeper.find_stale_documents(max_age_hours: 24)
      assert stale == []
    end

    test "respects max_age_hours option" do
      doc = document_fixture(%{status: "uploading"})

      {1, _} =
        Documents.Document
        |> where([d], d.id == ^doc.id)
        |> Doctrans.Repo.update_all(
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
        )

      # Should not find with 24 hour max age
      assert Sweeper.find_stale_documents(max_age_hours: 24) == []

      # Should find with 1 hour max age
      stale = Sweeper.find_stale_documents(max_age_hours: 1)
      stale_ids = Enum.map(stale, & &1.id)
      assert doc.id in stale_ids
    end

    test "respects statuses option" do
      doc1 = document_fixture(%{status: "uploading"})
      doc2 = document_fixture(%{status: "extracting"})

      for doc <- [doc1, doc2] do
        Documents.Document
        |> where([d], d.id == ^doc.id)
        |> Doctrans.Repo.update_all(
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
        )
      end

      # Only find uploading
      stale = Sweeper.find_stale_documents(statuses: ["uploading"])
      stale_ids = Enum.map(stale, & &1.id)
      assert doc1.id in stale_ids
      refute doc2.id in stale_ids
    end
  end

  describe "sweep_orphaned_directories/1" do
    test "removes orphaned directories", %{documents_dir: documents_dir} do
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      # Create a file inside to verify rm_rf works
      File.write!(Path.join(orphan_dir, "test.txt"), "content")

      assert {:ok, count} = Sweeper.sweep_orphaned_directories()
      assert count >= 1
      refute File.exists?(orphan_dir)
    end

    test "does not remove directories with database records", %{documents_dir: documents_dir} do
      doc = document_fixture()
      doc_dir = Path.join(documents_dir, doc.id)
      File.mkdir_p!(doc_dir)

      assert {:ok, 0} = Sweeper.sweep_orphaned_directories()
      assert File.exists?(doc_dir)
    end

    test "dry_run option does not delete", %{documents_dir: documents_dir} do
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      assert {:ok, 1} = Sweeper.sweep_orphaned_directories(dry_run: true)
      assert File.exists?(orphan_dir)
    end

    test "returns count of removed directories", %{documents_dir: documents_dir} do
      # Count existing orphaned directories first
      initial_orphaned = length(Sweeper.find_orphaned_directories())

      # Create multiple orphan directories
      for _ <- 1..3 do
        fake_uuid = Ecto.UUID.generate()
        File.mkdir_p!(Path.join(documents_dir, fake_uuid))
      end

      assert {:ok, count} = Sweeper.sweep_orphaned_directories()
      assert count == initial_orphaned + 3
    end
  end

  describe "sweep_stale_documents/1" do
    test "removes stale documents" do
      doc = document_fixture(%{status: "uploading"})

      Documents.Document
      |> where([d], d.id == ^doc.id)
      |> Doctrans.Repo.update_all(
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
      )

      assert {:ok, 1} = Sweeper.sweep_stale_documents()

      assert is_nil(Doctrans.Repo.get(Documents.Document, doc.id))
    end

    test "does not remove non-stale documents" do
      doc = document_fixture(%{status: "uploading"})

      assert {:ok, 0} = Sweeper.sweep_stale_documents()

      assert Doctrans.Repo.get(Documents.Document, doc.id) != nil
    end

    test "dry_run option does not delete" do
      doc = document_fixture(%{status: "uploading"})

      Documents.Document
      |> where([d], d.id == ^doc.id)
      |> Doctrans.Repo.update_all(
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
      )

      assert {:ok, 1} = Sweeper.sweep_stale_documents(dry_run: true)

      # Document should still exist
      assert Doctrans.Repo.get(Documents.Document, doc.id) != nil
    end
  end

  describe "sweep_all/1" do
    test "runs both orphaned and stale sweeps", %{documents_dir: documents_dir} do
      # Create an orphan directory
      fake_uuid = Ecto.UUID.generate()
      File.mkdir_p!(Path.join(documents_dir, fake_uuid))

      # Create a stale document
      doc = document_fixture(%{status: "uploading"})

      Documents.Document
      |> where([d], d.id == ^doc.id)
      |> Doctrans.Repo.update_all(
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
      )

      result = Sweeper.sweep_all()

      assert %{
               orphaned_directories: {:ok, 1},
               stale_documents: {:ok, 1}
             } = result
    end

    test "dry_run affects both sweeps", %{documents_dir: documents_dir} do
      # Create an orphan directory
      fake_uuid = Ecto.UUID.generate()
      orphan_dir = Path.join(documents_dir, fake_uuid)
      File.mkdir_p!(orphan_dir)

      # Create a stale document
      doc = document_fixture(%{status: "uploading"})

      Documents.Document
      |> where([d], d.id == ^doc.id)
      |> Doctrans.Repo.update_all(
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour)]
      )

      _result = Sweeper.sweep_all(dry_run: true)

      # Both should still exist
      assert File.exists?(orphan_dir)
      assert Doctrans.Repo.get(Documents.Document, doc.id) != nil
    end
  end
end
