defmodule Doctrans.StorageRootTest do
  # Repoints the shared storage root, so it must not run alongside async tests.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Resilience.HealthCheck

  @endpoint DoctransWeb.Endpoint

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

  test "images left in the default root are not served once it moves", %{root: root} do
    directory = "documents/#{Uniq.UUID.uuid7()}"
    stale = Path.join([Application.app_dir(:doctrans, "priv/static/uploads"), directory, "pages"])
    File.mkdir_p!(stale)
    on_exit(fn -> File.rm_rf!(Path.dirname(stale)) end)
    File.write!(Path.join(stale, "page-01.png"), "stale image")

    refute File.exists?(Path.join([root, directory, "pages", "page-01.png"]))

    assert get(build_conn(), "/uploads/#{directory}/pages/page-01.png").status == 404
  end
end
