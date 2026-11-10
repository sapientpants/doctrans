defmodule DoctransWeb.EndpointTest do
  use DoctransWeb.ConnCase, async: true

  alias Doctrans.Documents.Layout

  # Every path below is built from the configured storage root, which the test
  # environment deliberately places outside the application directory: serving
  # from anywhere else is the defect this covers.

  # Writes one page image under the storage root, removed when the test exits,
  # and returns the URL the upload server serves it at.
  defp page_image do
    directory = "documents/#{Uniq.UUID.uuid7()}/pages"
    path = Path.join(Layout.root(), directory)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    File.write!(Path.join(path, "page-01.png"), "page image content")

    "/uploads/#{directory}/page-01.png"
  end

  describe "uploaded page caching" do
    setup do
      {:ok, image_url: page_image()}
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

  # The field bounds are the control; the WebSocket bounds are what keep an
  # oversized event from being decoded at all (#267). Two of them, because
  # Bandit counts a single frame and a message split across continuation
  # frames separately, and a peer that is refused one way tries the other.
  # Both are exercised against a server, not read back from configuration:
  # the frame bound is set on the `/live` socket and the message bound on the
  # server, and only the wire shows that each is honoured where it was set.
  describe "the LiveView WebSocket" do
    @bound 1_000_000

    setup do
      websocket_options =
        Application.get_env(:doctrans, DoctransWeb.Endpoint)[:http][:websocket_options]

      pid =
        start_supervised!(
          {Bandit,
           plug: DoctransWeb.Endpoint,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           websocket_options: websocket_options}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      {:ok, port: port}
    end

    test "answers a frame within the bound", %{port: port} do
      socket = connect(port)
      :ok = :gen_tcp.send(socket, text_frame(heartbeat(@bound - 100)))

      assert {:text, reply} = recv_frame(socket)
      assert reply =~ "phx_reply"
      assert reply =~ ~s("status":"ok")
    end

    # Captured: the socket process reports the refusal, quoting the frame.
    @tag :capture_log
    test "closes on a single frame over the bound before reading it", %{port: port} do
      socket = connect(port)
      # The header alone: the server refuses on the declared length.
      :ok = :gen_tcp.send(socket, frame_header(:text, @bound + 1, fin: true))

      assert {:close, 1009} = recv_frame(socket)
    end

    @tag :capture_log
    test "closes on a message over the bound split across frames", %{port: port} do
      socket = connect(port)
      half = div(@bound, 2) + 1
      :ok = :gen_tcp.send(socket, frame(:text, String.duplicate("a", half), fin: false))
      :ok = :gen_tcp.send(socket, frame(:continuation, String.duplicate("a", half), fin: true))

      assert {:close, 1009} = recv_frame(socket)
    end

    defp connect(port) do
      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])

      key = Base.encode64(:crypto.strong_rand_bytes(16))

      request =
        "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\n" <>
          "Host: localhost:#{port}\r\n" <>
          "Origin: http://localhost\r\n" <>
          "Upgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"

      :ok = :gen_tcp.send(socket, request)
      response = recv_until(socket, "\r\n\r\n", "")
      assert response =~ "HTTP/1.1 101"
      socket
    end

    defp recv_until(socket, terminator, acc) do
      if String.contains?(acc, terminator) do
        acc
      else
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        recv_until(socket, terminator, acc <> data)
      end
    end

    # A Phoenix V2 heartbeat, padded to `size` bytes: the endpoint answers it
    # without a join, whatever it carries, so it proves a frame of that size
    # was decoded.
    defp heartbeat(size) do
      head = ~s([null,"1","phoenix","heartbeat",{"pad":")
      tail = ~s("}])
      head <> String.duplicate("a", size - byte_size(head) - byte_size(tail)) <> tail
    end

    defp text_frame(payload), do: frame(:text, payload, fin: true)

    # A client frame must be masked; a key of zero leaves the payload as it is.
    defp frame(opcode, payload, fin: fin),
      do: frame_header(opcode, byte_size(payload), fin: fin) <> payload

    defp frame_header(opcode, length, fin: fin) do
      opcode = %{continuation: 0, text: 1}[opcode]
      fin = if fin, do: 1, else: 0

      length =
        cond do
          length < 126 -> <<1::1, length::7>>
          length < 65_536 -> <<1::1, 126::7, length::16>>
          true -> <<1::1, 127::7, length::64>>
        end

      <<fin::1, 0::3, opcode::4>> <> length <> <<0::32>>
    end

    # One unmasked server frame, read whole. Only lengths under 64 kB appear:
    # a heartbeat reply and a close frame.
    defp recv_frame(socket, acc \\ "") do
      case frame_payload(acc) do
        {opcode, payload} ->
          decode_frame(opcode, payload)

        :incomplete ->
          {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
          recv_frame(socket, acc <> data)
      end
    end

    defp frame_payload(
           <<_::4, opcode::4, 0::1, 126::7, length::16, payload::binary-size(length), _::binary>>
         ),
         do: {opcode, payload}

    defp frame_payload(
           <<_::4, opcode::4, 0::1, length::7, payload::binary-size(length), _::binary>>
         )
         when length < 126,
         do: {opcode, payload}

    defp frame_payload(_partial), do: :incomplete

    defp decode_frame(1, payload), do: {:text, payload}
    defp decode_frame(8, <<code::16, _reason::binary>>), do: {:close, code}
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
      image_url = page_image()

      for url <- [
            "/",
            "/documents/#{Uniq.UUID.uuid7()}",
            "/documents/#{Uniq.UUID.uuid7()}/export.md",
            image_url,
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
