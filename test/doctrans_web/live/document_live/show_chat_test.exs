defmodule DoctransWeb.DocumentLive.ShowChatTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Doctrans.Chat.Conversations
  alias Doctrans.Documents
  alias Doctrans.Repo
  alias DoctransWeb.DocumentLive.Show

  describe "chat panel" do
    setup do
      document = create_completed_document_with_embeddings()
      %{document: document}
    end

    test "restores saved messages after remount and warns about an unfinished answer", %{
      conn: conn,
      document: document
    } do
      question = Conversations.start_question(document.id, "Saved question")

      {:ok, answer} =
        Conversations.finish(question, "assistant", "Saved answer", [])

      {:ok, first, _} = live(conn, ~p"/documents/#{document.id}")
      first |> element("header button[phx-click='toggle_chat']") |> render_click()
      assert has_element?(first, "#chat_messages-#{answer.id}")
      first |> element("header button[phx-click='toggle_chat']") |> render_click()
      first |> element("header button[phx-click='toggle_chat']") |> render_click()
      assert has_element?(first, "#chat_messages-#{answer.id}")
      GenServer.stop(first.pid)

      pending = Conversations.start_question(document.id, "Unfinished question")
      {:ok, restored, _} = live(conn, ~p"/documents/#{document.id}")
      restored |> element("header button[phx-click='toggle_chat']") |> render_click()
      assert has_element?(restored, "#chat_messages-#{answer.id}")
      assert has_element?(restored, "#chat_messages-#{pending.id}")
      assert has_element?(restored, "#chat-interrupted")
      assert has_element?(restored, "#chat-retention-note")
    end

    test "opening idle chat refreshes history, context, and the interrupted notice", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      question = Conversations.start_question(document.id, "Another tab's question")
      toggle = "header button[phx-click='toggle_chat']"
      view |> element(toggle) |> render_click()
      assert has_element?(view, "#chat-interrupted")
      view |> element(toggle) |> render_click()

      page = Documents.get_page_by_number(document.id, 1)

      context = [
        %{
          page_id: page.id,
          page_number: 1,
          chunk_index: 0,
          content_revision: page.content_revision,
          similarity: 0.9,
          original_markdown: "Source from another tab",
          translated_markdown: nil
        }
      ]

      {:ok, answer} = Conversations.finish(question, "assistant", "Another tab's answer", context)
      view |> element(toggle) |> render_click()
      assert has_element?(view, "#chat_messages-#{answer.id}")
      refute has_element?(view, "#chat-interrupted")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.chat_history == Conversations.load(document.id).history
      assert assigns.chat_retrieved_context == context
    end

    test "a page corrected elsewhere drops that page's accumulated context", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      page = Documents.get_page_by_number(document.id, 1)

      other =
        Repo.insert!(%Doctrans.Documents.Page{
          document_id: document.id,
          page_number: 2,
          image_path: "documents/#{document.id}/pages/page_2.png",
          original_markdown: "Unrelated",
          extraction_status: "completed",
          translation_status: "completed"
        })

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(:chat_retrieved_context, [
          context_chunk(page, "Assets are 10"),
          context_chunk(other, "Unrelated")
        ])

      {:ok, corrected} = Documents.reset_page_for_reprocessing(page)
      refute corrected.content_revision == page.content_revision

      {:noreply, updated} = Show.handle_info({:page_updated, corrected}, socket)

      assert Enum.map(updated.assigns.chat_retrieved_context, & &1.page_id) == [other.id]
    end

    test "reopening chat during generation preserves the active turn's state", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      socket = :sys.get_state(view.pid).socket
      question = Conversations.start_question(document.id, "Active question")

      socket =
        Phoenix.Component.assign(socket,
          chat_loading: true,
          chat_question: question,
          chat_last_question: question.content,
          chat_streaming_content: "Partial answer"
        )

      {:noreply, reopened} = Show.handle_event("toggle_chat", %{}, socket)

      assert reopened.assigns.chat_loading
      assert reopened.assigns.chat_question == question
      assert reopened.assigns.chat_streaming_content == "Partial answer"
      refute reopened.assigns.chat_interrupted
      assert reopened.assigns.chat_history == socket.assigns.chat_history
      assert reopened.assigns.chat_retrieved_context == socket.assigns.chat_retrieved_context
    end

    test "late response from a replaced run is discarded without waiting for PubSub", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      question = Conversations.start_question(document.id, "Old question")
      ref = make_ref()

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(
          chat_loading: true,
          chat_question: question,
          chat_task_ref: ref,
          chat_last_question: question.content
        )

      document
      |> Ecto.Changeset.change(processing_run_id: Ecto.UUID.generate())
      |> Repo.update!()

      {:noreply, updated} = Show.handle_info({ref, {:ok, "Stale answer", []}}, socket)
      refute updated.assigns.chat_loading
      assert updated.assigns.chat_task_ref == nil
      assert updated.assigns.chat_retrieved_context == []
      assert length(Conversations.load(document.id).messages) == 1
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

      # Close panel using the chat toggle button in the header
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

  defp context_chunk(page, content) do
    %{
      page_id: page.id,
      page_number: page.page_number,
      chunk_index: 0,
      content_revision: page.content_revision,
      similarity: 0.9,
      original_markdown: content,
      translated_markdown: nil
    }
  end

  defp create_completed_document_with_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de",
        status: "completed",
        total_pages: 1
      })

    # Use direct Repo insert to set deterministic embedding with Pgvector type
    embedding =
      List.duplicate(0.1, 1024)
      |> Pgvector.new()

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
