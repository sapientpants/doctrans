defmodule DoctransWeb.RootLayoutTest do
  # Sync: the remote case overrides the global `:openai` application env.
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.TestEnv
  alias DoctransWeb.PrivacyCopy

  defp head_meta(conn, selector) do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert [content] = document |> LazyHTML.query(selector) |> LazyHTML.attribute("content")
    content
  end

  describe "the page description" do
    test "is the privacy copy, not a hardcoded promise" do
      configure("http://localhost:8000")

      assert head_meta(build_conn(), ~s(meta[name="description"])) ==
               PrivacyCopy.meta_description()

      assert head_meta(build_conn(), ~s(meta[property="og:description"])) ==
               PrivacyCopy.tagline()
    end

    test "names the destination when inference is remote" do
      # Search engines and link previews read this and nothing else on the
      # page, so the dashboard's disclosure has to reach the <head> as well.
      configure("https://api.example.com")

      for selector <- [~s(meta[name="description"]), ~s(meta[property="og:description"])] do
        content = head_meta(build_conn(), selector)

        assert content =~ "api.example.com"
        refute content =~ "locally"
        refute content =~ "local AI"
      end
    end

    test "follows the request locale" do
      configure("http://localhost:8000")

      conn = build_conn() |> put_req_header("accept-language", "de")

      assert head_meta(conn, ~s(meta[name="description"])) =~ "Übersetzen"
    end
  end

  defp configure(chat_url) do
    TestEnv.put_env(:openai, base_url: chat_url, chat_model: "chat")
    TestEnv.put_env(:embedding, base_url: nil)
  end
end
