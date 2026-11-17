defmodule Doctrans.Processing.OpenAIBypass do
  @moduledoc """
  Responses for a Bypass server standing in for the inference API.

  The request-layer and health-check suites all point the real client at a
  local `Bypass` and answer its calls by hand. These are the answers they
  share: a JSON body with a status, the shape `GET /v1/models` has to come
  back in for `Doctrans.Processing.OpenAI.list_models/0` to parse it, and a
  redirect to a second server that reports whether it was followed.
  """

  import ExUnit.Callbacks

  @doc "Responds with `payload` encoded as JSON under `status`."
  def json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  @doc "Responds as a model server advertising exactly `ids`."
  def models(conn, ids) do
    json(conn, 200, %{"object" => "list", "data" => Enum.map(ids, &%{"id" => &1})})
  end

  @doc """
  Answers the next `method` request to `path` on `bypass` with a `status`
  redirect to the same path on a second server, which sends `:redirect_followed`
  to `test_pid` if anything reaches it.

  The second server answers 200 with a model list, so a followed redirect also
  changes the call's result rather than only the mailbox.
  """
  def redirect_elsewhere(bypass, method, path, status, test_pid) do
    redirect_target = Bypass.open()
    on_exit(fn -> Bypass.down(redirect_target) end)

    Bypass.stub(redirect_target, method, path, fn conn ->
      send(test_pid, :redirect_followed)
      models(conn, ["model-a"])
    end)

    Bypass.expect_once(bypass, method, path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://localhost:#{redirect_target.port}#{path}")
      |> Plug.Conn.resp(status, "")
    end)
  end
end
