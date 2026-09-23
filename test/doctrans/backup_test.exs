defmodule Doctrans.BackupTest do
  @moduledoc """
  Async: these tests repoint the global `:uploads` key at a root of their own.
  """

  use Doctrans.DataCase, async: false

  alias Doctrans.Backup

  import Doctrans.Fixtures

  setup do
    # A verification reads the whole root, so give it one holding only what the
    # test put there rather than the root the rest of the suite shares.
    previous = Application.fetch_env!(:doctrans, :uploads)
    root = Path.join(System.tmp_dir!(), "doctrans-backup-#{Uniq.UUID.uuid7()}")
    Application.put_env(:doctrans, :uploads, Keyword.put(previous, :upload_dir, root))

    on_exit(fn ->
      Application.put_env(:doctrans, :uploads, previous)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  describe "verify/0 on a consistent root" do
    test "reports a complete library with its counts", %{root: root} do
      document = document_with_pages_fixture(%{}, 3)
      document_source_fixture(document)
      Enum.each(document.pages, &write_under(root, &1.image_path))

      report = Backup.verify()

      assert report.root == root
      assert report.documents == 1
      assert report.pages == 3
      assert report.complete?
      assert report.missing == []
      assert report.extra == []
    end

    test "does not look for an original the app never retains" do
      # The format decides whether a source is kept at all, so a document that
      # records none is not a document whose file went astray.
      _document = document_fixture(%{original_filename: "notes.txt"})

      report = Backup.verify()

      assert report.complete?
      assert report.missing == []
    end

    test "ignores a page that has not been rendered yet" do
      document = document_fixture()
      document_source_fixture(document)
      page_fixture(document, %{image_path: nil})

      report = Backup.verify()

      # The page names no file, so there is no file the backup could have lost.
      assert report.pages == 1
      assert report.complete?
      assert report.missing == []
    end
  end

  describe "verify/0 on rows whose files are gone" do
    test "reports a retained original that is absent, relative to the root", %{root: root} do
      document = document_with_pages_fixture(%{}, 1)
      Enum.each(document.pages, &write_under(root, &1.image_path))

      report = Backup.verify()

      refute report.complete?

      assert report.missing == [
               {:source_missing,
                [document_id: document.id, path: "documents/#{document.id}/original.pdf"]}
             ]
    end

    test "aggregates missing page images into one reason per document", %{root: root} do
      document = document_with_pages_fixture(%{}, 3)
      document_source_fixture(document)
      document.pages |> Enum.take(1) |> Enum.each(&write_under(root, &1.image_path))

      report = Backup.verify()

      refute report.complete?

      assert report.missing == [
               {:page_images_missing, [document_id: document.id, missing: 2, of: 3]}
             ]
    end

    test "orders reasons by document id so two runs can be diffed" do
      first = document_fixture()
      second = document_fixture()

      report = Backup.verify()

      document_ids = Enum.map(report.missing, fn {_code, bindings} -> bindings[:document_id] end)
      assert document_ids == Enum.sort([first.id, second.id])
    end
  end

  describe "verify/0 on files no row owns" do
    test "reports an orphaned directory without failing the restore", %{root: root} do
      document = document_with_pages_fixture(%{}, 1)
      document_source_fixture(document)
      Enum.each(document.pages, &write_under(root, &1.image_path))

      stray_id = Uniq.UUID.uuid7()
      File.mkdir_p!(Path.join([root, "documents", stray_id]))

      report = Backup.verify()

      # Extras are the recoverable direction: the sweeper reclaims them.
      assert report.extra == [{:orphaned_document_dir, [path: "documents/#{stray_id}"]}]
      assert report.complete?
    end

    test "does not choke on an entry that is not a document id at all", %{root: root} do
      write_under(root, "documents/README.txt")

      report = Backup.verify()

      assert report.extra == [{:orphaned_document_dir, [path: "documents/README.txt"]}]
      assert report.complete?
    end

    test "sorts extras by path", %{root: root} do
      Enum.each(~w(zz.txt aa.txt mm.txt), &write_under(root, "documents/#{&1}"))

      report = Backup.verify()

      paths = Enum.map(report.extra, fn {_code, bindings} -> bindings[:path] end)
      assert paths == ~w(documents/aa.txt documents/mm.txt documents/zz.txt)
    end

    test "treats a root without a documents directory as empty", %{root: root} do
      refute File.exists?(root)

      report = Backup.verify()

      assert report.documents == 0
      assert report.pages == 0
      assert report.extra == []
      assert report.complete?
    end
  end

  describe "lines/1" do
    test "ends on a verdict that names the root it checked", %{root: root} do
      document = document_with_pages_fixture(%{}, 1)
      document_source_fixture(document)
      Enum.each(document.pages, &write_under(root, &1.image_path))

      lines = Backup.verify() |> Backup.lines()

      assert hd(lines) == "Storage root: #{root}"
      assert Enum.at(lines, 1) == "Checked 1 document(s) and 1 page(s)."
      assert List.last(lines) == "The database and #{root} agree."
    end

    test "renders every disagreement, and says so in the verdict", %{root: root} do
      document = document_with_pages_fixture(%{}, 1)
      File.mkdir_p!(Path.join([root, "documents", "stray"]))

      lines = Backup.verify() |> Backup.lines()

      assert Enum.any?(lines, &(&1 =~ "missing: {:source_missing" and &1 =~ document.id))
      assert Enum.any?(lines, &(&1 =~ "missing: {:page_images_missing"))
      assert Enum.any?(lines, &(&1 =~ "extra: {:orphaned_document_dir"))
      # Two reasons, one document: the count is of documents, not of findings.
      assert List.last(lines) == "1 document(s) name files that are not under #{root}."
    end
  end

  defp write_under(root, relative_path) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "placeholder")
    path
  end
end
