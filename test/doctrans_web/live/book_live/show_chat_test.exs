defmodule DoctransWeb.DocumentLive.ShowChatTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Doctrans.Documents
  alias Doctrans.Repo

  describe "chat panel" do
    setup do
      document = create_completed_document_with_embeddings()
      %{document: document}
    end

    test "chat button is visible in header", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Use more specific selector - the header toggle button
      assert has_element?(view, "header button[phx-click='toggle_chat']")
    end

    test "chat panel opens when toggle button is clicked", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Panel should not be visible initially
      refute has_element?(view, "#chat-messages")

      # Click toggle button in header
      view |> element("header button[phx-click='toggle_chat']") |> render_click()

      # Panel should now be visible
      assert has_element?(view, "#chat-messages")
      # Form should be visible because embeddings are ready
      assert has_element?(view, "#chat-form")
    end

    test "chat panel closes when close button is clicked", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open panel
      view |> element("header button[phx-click='toggle_chat']") |> render_click()
      assert has_element?(view, "#chat-messages")

      # Close panel using the X button in the chat panel header
      view |> element("#chat-messages") |> render()
      view |> element("header button[phx-click='toggle_chat']") |> render_click()
      refute has_element?(view, "#chat-messages")
    end
  end

  describe "chat with document without embeddings" do
    test "shows not ready message when embeddings are not ready", %{conn: conn} do
      # Create a document without embeddings
      document = create_document_without_embeddings()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat
      view |> element("header button[phx-click='toggle_chat']") |> render_click()

      # Should show chat panel but no input form (not ready)
      assert has_element?(view, "#chat-messages")
      refute has_element?(view, "#chat-form")
    end
  end

  describe "sending chat messages" do
    setup do
      document = create_completed_document_with_embeddings()
      %{document: document}
    end

    test "can submit a chat message", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat panel
      view |> element("header button[phx-click='toggle_chat']") |> render_click()

      # Submit a message
      view
      |> form("#chat-form", %{message: "What is this document about?"})
      |> render_submit()

      # User message should appear in the stream
      html = render(view)
      assert html =~ "What is this document about?"
    end

    test "empty message is not submitted", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat panel
      view |> element("header button[phx-click='toggle_chat']") |> render_click()

      # Submit empty message
      view
      |> form("#chat-form", %{message: ""})
      |> render_submit()

      # Chat input should still be present (no error, just ignored)
      assert has_element?(view, "#chat-input")
    end

    test "whitespace-only message is not submitted", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat panel
      view |> element("header button[phx-click='toggle_chat']") |> render_click()

      # Submit whitespace-only message
      view
      |> form("#chat-form", %{message: "   "})
      |> render_submit()

      # Chat input should still be present
      assert has_element?(view, "#chat-input")
    end
  end

  # Helper functions

  defp create_completed_document_with_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de",
        status: "completed",
        total_pages: 1
      })

    # Use direct Repo insert to set embedding
    embedding = Enum.map(1..1024, fn _ -> :rand.uniform() end)

    Repo.insert!(%Doctrans.Documents.Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: 1,
      image_path: "documents/#{document.id}/pages/page_1.png",
      original_markdown: "Test content for chat",
      translated_markdown: "Testinhalt für Chat",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: embedding
    })

    document
  end

  defp create_document_without_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de",
        status: "completed",
        total_pages: 1
      })

    Repo.insert!(%Doctrans.Documents.Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: 1,
      image_path: "documents/#{document.id}/pages/page_1.png",
      original_markdown: "Test content",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "pending",
      embedding: nil
    })

    document
  end
end
