defmodule DoctransWeb.DocumentLive.PrivacyNoticeTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.TestEnv

  # Every claim on this page is a separate element, and each has to be checked
  # through its own selector. Matching the whole rendered page instead lets one
  # paragraph satisfy an assertion meant for another -- the empty state names the
  # host, so `html =~ "api.example.com"` passes even with the tagline still
  # promising local-only processing.
  @tagline "#privacy-tagline"
  @empty_state "#documents-empty"
  @upload_notice "#upload-privacy-notice"

  defp configure(chat_url, opts \\ []) do
    TestEnv.put_env(
      :openai,
      [base_url: chat_url, chat_model: "chat"] ++ Keyword.take(opts, [:api_key])
    )

    TestEnv.put_env(:embedding, base_url: Keyword.get(opts, :embedding_url))
  end

  defp open_upload_modal(view) do
    view |> element("#upload-document-btn") |> render_click()
    view
  end

  defp text(view, selector), do: view |> element(selector) |> render()

  describe "a local endpoint" do
    setup %{conn: conn} do
      configure("http://localhost:8000")
      {:ok, view, _html} = live(conn, ~p"/")
      %{view: view}
    end

    test "keeps the on-device promise in the tagline and the empty state", %{view: view} do
      assert text(view, @tagline) =~ "local AI"
      assert text(view, @empty_state) =~ "All processing happens locally on your device."
    end

    test "keeps the promise and its padlock in the upload modal", %{view: view} do
      view = open_upload_modal(view)

      assert text(view, @upload_notice) =~ "never leave your device"
      assert has_element?(view, "#{@upload_notice} span.hero-lock-closed")
    end
  end

  describe "a remote chat endpoint" do
    setup %{conn: conn} do
      configure("https://api.example.com")
      {:ok, view, _html} = live(conn, ~p"/")
      %{view: view}
    end

    test "replaces the promise and names the host in the tagline", %{view: view} do
      assert text(view, @tagline) =~ "api.example.com"
      refute text(view, @tagline) =~ "local AI"
    end

    test "replaces the promise and names the host in the empty state", %{view: view} do
      assert text(view, @empty_state) =~ "api.example.com"
      refute text(view, @empty_state) =~ "All processing happens locally on your device."
    end

    test "drops the promise and the padlock from the upload modal", %{view: view} do
      view = open_upload_modal(view)

      assert text(view, @upload_notice) =~ "api.example.com"
      refute text(view, @upload_notice) =~ "never leave your device"
      refute has_element?(view, "#{@upload_notice} span.hero-lock-closed")
      assert has_element?(view, "#{@upload_notice} span.hero-arrow-up-tray")
    end
  end

  # The branch's headline insight: an embedding request carries the chunk text it
  # is embedding, so a remote embedding host is document egress even when chat
  # stays on the machine. Module-level tests cover the classification; this
  # covers the page actually saying so.
  test "a local chat endpoint with a remote embedding endpoint still names the destination",
       %{conn: conn} do
    configure("http://localhost:8000", embedding_url: "https://embeddings.example.com")

    {:ok, view, _html} = live(conn, ~p"/")

    assert text(view, @tagline) =~ "embeddings.example.com"
    refute text(view, @tagline) =~ "local AI"
    assert text(view, @empty_state) =~ "embeddings.example.com"
  end

  test "an unreadable endpoint names the configured value rather than promising anything",
       %{conn: conn} do
    configure("llm:8000")

    {:ok, view, _html} = live(conn, ~p"/")

    assert text(view, @tagline) =~ "llm:8000"
    refute text(view, @empty_state) =~ "All processing happens locally on your device."
  end

  test "the configured API key never reaches the rendered page", %{conn: conn} do
    # The log half of this guarantee is pinned in reprocess_modal_test.exs; this
    # is its counterpart for the DOM.
    configure("https://api.example.com", api_key: "sk-must-not-be-rendered")

    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "sk-must-not-be-rendered"
    refute view |> open_upload_modal() |> render() =~ "sk-must-not-be-rendered"
  end

  test "credentials in an endpoint URL never reach the rendered page", %{conn: conn} do
    # No parseable host, so this takes the branch that renders the URL itself.
    configure("user:s3cret@llm.example.com:8000")

    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "s3cret"
    assert text(view, @tagline) =~ "llm.example.com"
    refute view |> open_upload_modal() |> render() =~ "s3cret"
  end
end
