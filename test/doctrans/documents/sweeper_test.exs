defmodule Doctrans.Documents.SweeperTest do
  # Repoints the global `:uploads` key, so it cannot run alongside async tests.
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents.Sweeper
  alias Doctrans.TestEnv

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  setup do
    # Sweep tests delete every directory the root contains, so give them a root
    # of their own rather than emptying the one the rest of the suite shares.
    previous = Application.fetch_env!(:doctrans, :uploads)
    uploads_dir = Path.join(System.tmp_dir!(), "doctrans-sweeper-#{Uniq.UUID.uuid7()}")
    TestEnv.put_env(:uploads, Keyword.put(previous, :upload_dir, uploads_dir))

    documents_dir = Path.join(uploads_dir, "documents")
    File.mkdir_p!(documents_dir)

    on_exit(fn -> File.rm_rf!(uploads_dir) end)

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

    test "never returns a foreign directory, however old", %{documents_dir: documents_dir} do
      # A storage root shared with other data (a home directory, a NAS share)
      # has folders under documents/ that no row will ever own. They are not
      # orphans: this application did not create them.
      foreign = Path.join(documents_dir, "Invoices")
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, "2024.pdf"), "tax return")
      File.touch!(foreign, System.os_time(:second) - 48 * 60 * 60)

      orphan = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(orphan)

      orphaned = capture_sweep(fn -> Sweeper.find_orphaned_directories(grace_period_hours: 0) end)

      refute foreign in orphaned
      assert orphan in orphaned
    end

    test "a directory named by a UUID the layout would not write is foreign", %{
      documents_dir: documents_dir
    } do
      # Only the lowercase hyphenated form `to_string/1` gives a document id is
      # a document directory; another spelling is a name some other program chose.
      for name <- [String.upcase(Ecto.UUID.generate()), Uniq.UUID.uuid7(:hex)] do
        File.mkdir_p!(Path.join(documents_dir, name))
      end

      assert capture_sweep(fn -> Sweeper.find_orphaned_directories(grace_period_hours: 0) end) ==
               []
    end

    test "logs each foreign directory it steps around", %{documents_dir: documents_dir} do
      File.mkdir_p!(Path.join(documents_dir, "Invoices"))

      log = capture_log(fn -> Sweeper.find_orphaned_directories(grace_period_hours: 0) end)

      assert log =~ ~s(skipping foreign directory "Invoices")
    end

    test "ignores files, only returns directories", %{documents_dir: documents_dir} do
      # A file (not a directory) is neither an orphan nor a foreign directory:
      # a sweep never removes a file, so one is not worth a warning either.
      file_path = Path.join(documents_dir, "some_file.txt")
      File.write!(file_path, "test")

      log =
        capture_log(fn ->
          refute file_path in Sweeper.find_orphaned_directories(grace_period_hours: 0)
        end)

      refute log =~ "skipping"
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

  describe "validate_root!/0" do
    test "a root whose documents/ already holds foreign directories is rejected", %{
      documents_dir: documents_dir
    } do
      # The shape of a home directory on macOS, where documents/ and Documents/ are
      # one folder: a sweep would delete these within a minute of boot.
      for name <- ["Invoices", "Tax-2024"] do
        File.mkdir_p!(Path.join(documents_dir, name))
      end

      error = assert_raise ArgumentError, &Sweeper.validate_root!/0
      assert error.message =~ "not dedicated to Doctrans"
      assert error.message =~ ~s("Invoices", "Tax-2024")
      assert error.message =~ "DOCTRANS_DATA_DIR"
    end

    test "a root whose documents/ holds only document directories and loose files is accepted",
         %{documents_dir: documents_dir} do
      File.mkdir_p!(Path.join(documents_dir, Uniq.UUID.uuid7()))
      File.mkdir_p!(Path.join(documents_dir, Ecto.UUID.generate()))
      # Finder leaves this behind; a file is never swept, so it is not a sign of a shared root.
      File.write!(Path.join(documents_dir, ".DS_Store"), "")

      assert Sweeper.validate_root!() == Path.dirname(documents_dir)
    end

    test "a fresh root with no documents/ directory is accepted", %{documents_dir: documents_dir} do
      File.rm_rf!(Path.dirname(documents_dir))

      assert Sweeper.validate_root!() == Path.dirname(documents_dir)
    end
  end

  describe "sweep/1" do
    test "grace period preserves a file during a concurrent read and expired orphans are removed",
         %{
           documents_dir: documents_dir
         } do
      orphan_dir = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(orphan_dir)
      path = Path.join(orphan_dir, "page.png")
      File.write!(path, "first chunk;last chunk")
      owner = self()

      # Hold an open file across both sweeps, as an in-flight file response does.
      # Messages establish ordering without relying on sleeps or a large file.
      reader =
        Task.async(fn ->
          File.open!(path, [:read, :binary], fn file ->
            send(owner, {:reading, self(), IO.binread(file, 12)})

            receive do
              :finish -> IO.binread(file, :eof)
            after
              5_000 -> raise "sweep did not release the reader"
            end
          end)
        end)

      assert_receive {:reading, reader_pid, "first chunk;"}
      assert {:ok, 0} = Sweeper.sweep()
      assert File.read!(path) == "first chunk;last chunk"

      # Age the directory (the sweeper uses directory mtime, not file atime).
      expired = System.os_time(:second) - 25 * 60 * 60
      File.touch!(orphan_dir, expired)
      assert {:ok, 1} = Sweeper.sweep()
      refute File.exists?(path)

      # POSIX open descriptors remain readable after unlink; the grace period
      # does not promise to preserve paths for new requests after expiry.
      send(reader_pid, :finish)
      assert Task.await(reader) == "last chunk"
    end

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

    test "leaves a foreign directory in place and still removes real orphans", %{
      documents_dir: documents_dir
    } do
      foreign = Path.join(documents_dir, "Tax-2024")
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, "return.pdf"), "tax return")
      File.touch!(foreign, System.os_time(:second) - 48 * 60 * 60)

      orphan = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(orphan)

      assert capture_sweep(fn -> Sweeper.sweep(grace_period_hours: 0) end) == {:ok, 1}

      assert File.exists?(Path.join(foreign, "return.pdf"))
      refute File.exists?(orphan)
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

    test "reports the orphans it could not remove instead of only logging them", %{
      documents_dir: documents_dir
    } do
      removable = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(removable)

      # Removing a file needs write permission on its directory, so a read-only
      # orphan with contents is one the sweeper can never delete -- as the
      # unprivileged user the suite and CI run as; root is kept out of nothing.
      stuck = Path.join(documents_dir, Ecto.UUID.generate())
      File.mkdir_p!(stuck)
      File.write!(Path.join(stuck, "page.png"), "rendered page")
      File.chmod!(stuck, 0o555)
      on_exit(fn -> File.chmod!(stuck, 0o755) end)

      log =
        capture_log(fn ->
          assert {:error, {:sweep_incomplete, [deleted: 1, failed: [^stuck]]}} =
                   Sweeper.sweep(grace_period_hours: 0)
        end)

      assert log =~ "Failed to delete orphaned directory #{stuck}"
      refute File.exists?(removable)
      assert File.exists?(stuck)
    end
  end

  # Runs a sweeper call for its return value, keeping its log out of the test output.
  defp capture_sweep(fun), do: fun |> with_log() |> elem(0)
end
