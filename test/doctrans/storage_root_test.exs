defmodule Doctrans.StorageRootTest do
  # Repoints the shared storage root, so it must not run alongside async tests.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents
  alias Doctrans.Resilience.HealthCheck

  setup do
    previous = Application.fetch_env!(:doctrans, :uploads)
    root = Path.join(System.tmp_dir!(), "doctrans-root-#{Uniq.UUID.uuid7()}")
    Application.put_env(:doctrans, :uploads, Keyword.put(previous, :upload_dir, root))

    on_exit(fn ->
      Application.put_env(:doctrans, :uploads, previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "a storage root chosen after boot is created and reported healthy", %{root: root} do
    assert Documents.uploads_dir() == root
    refute File.exists?(root)
    assert {:error, {:uploads_directory_missing, _}} = HealthCheck.check_filesystem()

    assert Documents.ensure_uploads_dir!() == root
    assert File.dir?(root)
    assert HealthCheck.check_filesystem() == :ok
  end

  test "page images are served from the storage root that stored them", %{root: root} do
    directory = "documents/#{Uniq.UUID.uuid7()}"
    pages = Path.join([root, directory, "pages"])
    File.mkdir_p!(pages)
    File.write!(Path.join(pages, "page-01.png"), "page image content")

    conn = get(build_conn(), "/uploads/#{directory}/pages/page-01.png")

    assert response(conn, 200) == "page image content"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "retained sources under a nondefault root stay inaccessible", %{root: root} do
    directory = "documents/#{Uniq.UUID.uuid7()}"
    document_dir = Path.join(root, directory)
    File.mkdir_p!(document_dir)

    for file <- ["original.pdf", "original.docx"] do
      File.write!(Path.join(document_dir, file), "retained source")
      assert get(build_conn(), "/uploads/#{directory}/#{file}").status == 404
    end
  end

  test "images left under the previous root stop being served once it moves", %{root: root} do
    directory = "documents/#{Uniq.UUID.uuid7()}"
    File.mkdir_p!(Path.join([root, directory, "pages"]))
    File.write!(Path.join([root, directory, "pages", "page-01.png"]), "stale image")

    # Served while this root is the configured one...
    assert get(build_conn(), "/uploads/#{directory}/pages/page-01.png").status == 200

    # ...and no longer once the root moves on, rather than being served from
    # whichever directory was baked in. A second temporary root stands in for the
    # new location: pointing at the real default would write into live storage.
    moved = Path.join(System.tmp_dir!(), "doctrans-moved-#{Uniq.UUID.uuid7()}")
    on_exit(fn -> File.rm_rf!(moved) end)
    Application.put_env(:doctrans, :uploads, upload_dir: moved, max_file_size: 1)

    refute File.exists?(Path.join([moved, directory, "pages", "page-01.png"]))
    assert get(build_conn(), "/uploads/#{directory}/pages/page-01.png").status == 404
  end

  test "a storage root inside the served static directory is rejected at startup" do
    for segment <- ["images", "assets"] do
      root = Path.join([Application.app_dir(:doctrans, "priv/static"), segment, "data"])
      Application.put_env(:doctrans, :uploads, upload_dir: root, max_file_size: 1)

      assert_raise ArgumentError, ~r/statically served directory/, &Uploads.validate_root!/0
    end
  end

  test "the default root is accepted even though it sits under priv/static" do
    Application.put_env(:doctrans, :uploads, max_file_size: 1)

    assert Uploads.validate_root!() == Application.app_dir(:doctrans, "priv/static/uploads")
  end

  test "an unwritable storage root names the setting to correct", %{root: root} do
    File.mkdir_p!(root)
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)

    Application.put_env(:doctrans, :uploads,
      upload_dir: Path.join(root, "nested"),
      max_file_size: 1
    )

    assert_raise RuntimeError, ~r/DOCTRANS_DATA_DIR/, &Documents.ensure_uploads_dir!/0
  end

  test "an unwritable storage root is reported unhealthy", %{root: root} do
    File.mkdir_p!(root)
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)

    assert {:error, {:uploads_directory_unwritable, _}} = HealthCheck.check_filesystem()
  end
end
