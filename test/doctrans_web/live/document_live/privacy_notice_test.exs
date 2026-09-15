defmodule DoctransWeb.DocumentLive.PrivacyNoticeTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.TestEnv

  defp configure(chat_url, opts \\ []) do
    TestEnv.put_env(
      :openai,
      [base_url: chat_url, chat_model: "chat"] ++ Keyword.take(opts, [:api_key])
    )

    TestEnv.put_env(:embedding, base_url: nil)
  end

  test "a local endpoint keeps the on-device promise", %{conn: conn} do
    configure("http://localhost:8000")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "All processing happens locally on your device."
  end

  test "a remote endpoint replaces the promise and names the host", %{conn: conn} do
    configure("https://api.example.com")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "api.example.com"
    refute html =~ "All processing happens locally on your device."
    refute html =~ "never leave your device"
  end

  test "the configured API key never reaches the rendered page", %{conn: conn} do
    # The log half of this guarantee is pinned in reprocess_modal_test.exs; this
    # is its counterpart for the DOM.
    configure("https://api.example.com", api_key: "sk-must-not-be-rendered")

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "sk-must-not-be-rendered"
  end
end
