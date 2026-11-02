defmodule Doctrans.Processing.OpenAIBypass do
  @moduledoc """
  Responses for a Bypass server standing in for the inference API.

  The request-layer and health-check suites all point the real client at a
  local `Bypass` and answer its calls by hand. These are the two answers they
  share: a JSON body with a status, and the shape `GET /v1/models` has to come
  back in for `Doctrans.Processing.OpenAI.list_models/0` to parse it.
  """

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
end
