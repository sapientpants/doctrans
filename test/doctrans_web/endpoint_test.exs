defmodule DoctransWeb.EndpointTest do
  use DoctransWeb.ConnCase, async: true

  @endpoint DoctransWeb.Endpoint

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
