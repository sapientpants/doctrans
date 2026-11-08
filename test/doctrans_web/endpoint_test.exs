defmodule DoctransWeb.EndpointTest do
  use DoctransWeb.ConnCase, async: true

  alias Doctrans.Documents.Layout

  # Every path below is built from the configured storage root, which the test
  # environment deliberately places outside the application directory: serving
  # from anywhere else is the defect this covers.

  describe "uploaded page caching" do
    setup do
      directory = "documents/#{Uniq.UUID.uuid7()}/pages"
      path = Path.join(Layout.root(), directory)
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
    root = Path.join(Layout.root(), directory)
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

  # The plug is first in the endpoint, ahead of `Plug.Static` and the upload
  # server, so every GET surface that carries document content without a
  # socket is covered: the dashboard's dead render, the viewer, the Markdown
  # export, and the page images (#260). The connection's host is set directly:
  # `Phoenix.ConnTest` builds every connection for `www.example.com`, which the
  # test configuration lists, and this is what a DNS-rebinding page's request
  # looks like once its name resolves to this machine.
  describe "a request for a host this deployment does not answer to" do
    @tag :capture_log
    test "is refused before the router, the static server and the upload server" do
      directory = "documents/#{Uniq.UUID.uuid7()}/pages"
      path = Path.join(Layout.root(), directory)
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)
      File.write!(Path.join(path, "page-01.png"), "page image content")

      for url <- [
            "/",
            "/documents/#{Uniq.UUID.uuid7()}",
            "/documents/#{Uniq.UUID.uuid7()}/export.md",
            "/uploads/#{directory}/page-01.png",
            "/robots.txt"
          ] do
        conn = get(%{build_conn() | host: "attacker.example"}, url)

        assert conn.status == 421, "#{url} was served for a foreign host"
        assert conn.halted
        refute conn.resp_body =~ "page image content"
      end
    end

    test "while the same requests are served for a listed host" do
      assert get(%{build_conn() | host: "localhost"}, "/robots.txt").status == 200
      assert get(%{build_conn() | host: "127.0.0.1"}, "/robots.txt").status == 200
      assert get(%{build_conn() | host: "[::1]"}, "/robots.txt").status == 200
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
