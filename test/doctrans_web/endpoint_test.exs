defmodule DoctransWeb.EndpointTest do
  use DoctransWeb.ConnCase, async: true

  @endpoint DoctransWeb.Endpoint

  alias Doctrans.Documents

  # Every path below is built from the configured storage root, which the test
  # environment deliberately places outside the application directory: serving
  # from anywhere else is the defect this covers.

  describe "uploaded page caching" do
    setup do
      directory = "documents/#{Uniq.UUID.uuid7()}/pages"
      path = Path.join(Documents.uploads_dir(), directory)
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)
      File.write!(Path.join(path, "page-01.png"), "page image content")

      {:ok, image_url: "/uploads/#{directory}/page-01.png"}
    end

    test "ordinary and versioned images cannot be stored in caches", %{image_url: url} do
      for query <- ["", "?vsn=123"] do
        conn = get(build_conn(), url <> query)

        assert response(conn, 200) == "page image content"
        assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      end
    end

    test "conditional responses retain the private cache policy", %{image_url: url} do
      conn = get(build_conn(), url)
      [etag] = get_resp_header(conn, "etag")

      conn =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get(url)

      assert response(conn, 304) == ""
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  test "only generated images are served from legacy and run directories" do
    directory = "documents/#{Uniq.UUID.uuid7()}"
    run = "runs/#{Uniq.UUID.uuid7()}"
    root = Path.join(Documents.uploads_dir(), directory)
    on_exit(fn -> File.rm_rf!(root) end)

    images = ["pages/page-01.png", "#{run}/pages/page-002.png"]

    private_files = [
      "original.pdf",
      "original.docx",
      "original.doc",
      "original.odt",
      "original.rtf",
      "#{run}/original.pdf",
      "pages/original.pdf",
      "pages/notes.png"
    ]

    for file <- images ++ private_files do
      path = Path.join(root, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "stored bytes")
    end

    for file <- images do
      conn = get(build_conn(), "/uploads/#{directory}/#{file}")
      assert response(conn, 200) == "stored bytes"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    for file <- private_files, query <- ["", "?vsn=123"], method <- [:get, :head] do
      conn = dispatch(build_conn(), @endpoint, method, "/uploads/#{directory}/#{file}#{query}")
      assert conn.status == 404
    end

    for file <- ["%6Friginal.pdf", "pages/../original.pdf", "pages/%2e%2e/original.pdf"] do
      assert get(build_conn(), "/uploads/#{directory}/#{file}").status == 404
    end
  end

  test "public static assets retain versioned caching" do
    conn = get(build_conn(), "/robots.txt?vsn=123")

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "the session cookie is encrypted, not just signed" do
    # The session is primed before dispatch: the fetch marker is set manually
    # because the conn is built outside the endpoint, whose Plug.Session plug
    # would normally fetch it. The dashboard route then runs :fetch_session,
    # forcing the endpoint to encode the session as a response cookie.
    conn =
      build_conn()
      |> put_private(:plug_session, %{})
      |> put_private(:plug_session_fetch, :done)
      |> put_session(:probe, "value")

    # Signed-only session cookies are JWS-style "protected.payload.signature"
    # values; encrypted cookies are JWE-style and carry the "XCP." prefix.
    conn = get(conn, "/")

    assert %{"_doctrans_key" => cookie} = conn.resp_cookies
    assert cookie.value |> String.starts_with?("XCP.")
    assert cookie.http_only
  end
end
