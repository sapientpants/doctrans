defmodule DoctransWeb.DocumentLive.ShowChatTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Chat.{Conversations, RetrievedContext}
  alias Doctrans.Documents
  alias Doctrans.Documents.Lifecycle
  alias Doctrans.Documents.PageLifecycle
  alias Doctrans.Repo
  alias DoctransWeb.DocumentLive.ChatComponents
  alias DoctransWeb.DocumentLive.ChatSession
  alias DoctransWeb.DocumentLive.Show

  describe "chat panel" do
    setup do
      document = completed_document_with_embedding_fixture()
      %{document: document}
    end

    test "restores saved messages after remount and warns about an unfinished answer", %{
      conn: conn,
      document: document
    } do
      question = Conversations.start_question(document.id, "Saved question")

      {:ok, answer, _} =
        Conversations.finish(question, "assistant", "Saved answer", RetrievedContext.new())

      {:ok, first, _} = live(conn, ~p"/documents/#{document.id}")
      first |> element("#toggle-chat") |> render_click()
      assert has_element?(first, "#chat_messages-#{answer.id}")
      first |> element("#toggle-chat") |> render_click()
      first |> element("#toggle-chat") |> render_click()
      assert has_element?(first, "#chat_messages-#{answer.id}")
      GenServer.stop(first.pid)

      pending = Conversations.start_question(document.id, "Unfinished question")
      {:ok, restored, _} = live(conn, ~p"/documents/#{document.id}")
      restored |> element("#toggle-chat") |> render_click()
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
      toggle = "#toggle-chat"
      view |> element(toggle) |> render_click()
      assert has_element?(view, "#chat-interrupted")
      view |> element(toggle) |> render_click()

      page = Documents.get_page_by_number(document.id, 1)

      context =
        RetrievedContext.add(RetrievedContext.new(), [
          %{
            page_id: page.id,
            page_number: 1,
            chunk_index: 0,
            content_revision: page.content_revision,
            similarity: 0.9,
            original_markdown: "Source from another tab",
            translated_markdown: nil
          }
        ])

      {:ok, answer, _saved} =
        Conversations.finish(question, "assistant", "Another tab's answer", context)

      view |> element(toggle) |> render_click()
      assert has_element?(view, "#chat_messages-#{answer.id}")
      refute has_element?(view, "#chat-interrupted")

      # The refreshed context is what the next turn reads, and nothing renders it.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.chat_history == Conversations.load(document.id).history
      assert assigns.chat_retrieved_context == context
    end

    test "chat button is visible in header", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, "header #toggle-chat")
    end

    test "chat panel opens when toggle button is clicked", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Panel should not be visible initially
      refute has_element?(view, "#chat-messages")

      # Click toggle button in header
      view |> element("#toggle-chat") |> render_click()

      # Panel should now be visible
      assert has_element?(view, "#chat-messages")
      # Form should be visible because embeddings are ready
      assert has_element?(view, "#chat-form")
    end

    test "chat panel closes when close button is clicked", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open panel
      view |> element("#toggle-chat") |> render_click()
      assert has_element?(view, "#chat-messages")

      # Close panel using the chat toggle button in the header
      view |> element("#toggle-chat") |> render_click()
      refute has_element?(view, "#chat-messages")
    end
  end

  # The events these react to -- a page broadcast from another tab, the result
  # or exit of a turn that was superseded or interrupted -- arrive on the
  # LiveView at a moment no rendered test can pin, and most of them leave nothing
  # on screen: the Retrieved context is state the next turn reads, not markup.
  # So the callbacks are driven directly on the mounted socket, and the `chat_*`
  # assigns are asserted by name. A rename in `ChatSession` is a rename here.
  describe "the Retrieved context, driven through the callbacks" do
    setup do
      document = completed_document_with_embedding_fixture()
      %{document: document}
    end

    test "a page corrected elsewhere drops that page's Retrieved context", %{
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
        |> Phoenix.Component.assign(
          :chat_retrieved_context,
          retrieved_context_fixture([
            passage_fixture(page, original_markdown: "Assets are 10"),
            passage_fixture(other, original_markdown: "Unrelated")
          ])
        )

      {:ok, corrected} = PageLifecycle.reset(page)
      refute corrected.content_revision == page.content_revision

      {:noreply, updated} = Show.handle_info({:page_updated, corrected}, socket)

      assert Enum.map(passages(updated.assigns.chat_retrieved_context), & &1.page_id) == [
               other.id
             ]
    end

    test "a page translated elsewhere drops that page's untranslated context", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")

      # Extracted but not yet translated: page embeddings are ready in this
      # window, so a turn can retrieve the page before its translation exists.
      untranslated =
        Repo.insert!(%Doctrans.Documents.Page{
          document_id: document.id,
          page_number: 2,
          image_path: "documents/#{document.id}/pages/page_2.png",
          original_markdown: "Aktiva sind 10",
          extraction_status: "completed",
          translation_status: "processing"
        })

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(
          :chat_retrieved_context,
          retrieved_context_fixture([
            page_passage_fixture(untranslated),
            passage_fixture(untranslated, original_markdown: "Aktiva sind 10")
          ])
        )

      {:ok, translated} =
        PageLifecycle.complete(untranslated, :translation, %{markdown: "Assets are 10"})

      assert translated.content_revision == untranslated.content_revision

      {:noreply, updated} = Show.handle_info({:page_updated, translated}, socket)

      # The page-level copy is untranslated and gone; chunk passages, which never
      # carry a translation, are untouched.
      assert Enum.map(passages(updated.assigns.chat_retrieved_context), & &1.chunk_index) == [0]
    end

    test "a whole-page passage carrying the current translation survives the update", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")

      page =
        Repo.insert!(%Doctrans.Documents.Page{
          document_id: document.id,
          page_number: 3,
          image_path: "documents/#{document.id}/pages/page_3.png",
          original_markdown: "Aktiva sind 10",
          translated_markdown: "Assets are 10",
          extraction_status: "completed",
          translation_status: "completed"
        })

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(
          :chat_retrieved_context,
          retrieved_context_fixture([page_passage_fixture(page)])
        )

      {:noreply, updated} = Show.handle_info({:page_updated, page}, socket)

      assert Enum.map(passages(updated.assigns.chat_retrieved_context), & &1.page_id) == [page.id]
    end

    test "an unrelated page's update leaves the Retrieved context alone", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")

      kept =
        Repo.insert!(%Doctrans.Documents.Page{
          document_id: document.id,
          page_number: 4,
          image_path: "documents/#{document.id}/pages/page_4.png",
          original_markdown: "Aktiva sind 10",
          extraction_status: "completed",
          translation_status: "processing"
        })

      {:ok, other} =
        PageLifecycle.complete(
          Repo.insert!(%Doctrans.Documents.Page{
            document_id: document.id,
            page_number: 5,
            image_path: "documents/#{document.id}/pages/page_5.png",
            original_markdown: "Aktiva sind 20",
            extraction_status: "completed",
            translation_status: "processing"
          }),
          :translation,
          %{
            markdown: "Assets are 20"
          }
        )

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(
          :chat_retrieved_context,
          retrieved_context_fixture([page_passage_fixture(kept)])
        )

      {:noreply, updated} = Show.handle_info({:page_updated, other}, socket)

      assert Enum.map(passages(updated.assigns.chat_retrieved_context), & &1.page_id) == [kept.id]
    end

    test "an answer finishing after a page correction keeps neither socket nor saved context", %{
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

      question = Conversations.start_question(document.id, "How much are assets?")

      context =
        retrieved_context_fixture([
          passage_fixture(page, original_markdown: "Assets are 10"),
          passage_fixture(other, original_markdown: "Unrelated")
        ])

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(:chat_question, question)
        |> Phoenix.Component.assign(:chat_last_question, question.content)

      # The page is corrected while this answer is still generating.
      {:ok, _corrected} = PageLifecycle.reset(page)

      assert {:ok, answered} = ChatSession.put_response(socket, "Assets are 10", context)

      assert Enum.map(passages(answered.assigns.chat_retrieved_context), & &1.page_id) == [
               other.id
             ]

      assert Enum.map(passages(Conversations.load(document.id).context), & &1.page_id) == [
               other.id
             ]
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
      token = make_ref()

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(
          chat_loading: true,
          chat_question: question,
          chat_token: token,
          chat_last_question: question.content
        )

      # A fresh run replaces the one the turn was asked under; inside a
      # transaction the transition stays silent, so only the stale result
      # below reaches the socket.
      {:ok, {:ok, _requeued}} =
        Repo.transaction(fn ->
          Lifecycle.requeue(document, run_attrs_fixture())
        end)

      result = {:ok, {token, {:ok, "Stale answer", RetrievedContext.new()}}}
      {:noreply, updated} = Show.handle_async(:chat_turn, result, socket)
      refute updated.assigns.chat_loading
      assert updated.assigns.chat_token == nil
      assert updated.assigns.chat_retrieved_context == RetrievedContext.new()
      assert length(Conversations.load(document.id).messages) == 1
    end

    test "a result or exit from an interrupted turn is dropped", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      question = Conversations.start_question(document.id, "Interrupted question")

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(
          chat_loading: true,
          chat_question: question,
          chat_token: make_ref(),
          chat_last_question: question.content
        )

      interrupted = ChatSession.interrupt(socket)
      refute interrupted.assigns.chat_loading
      assert interrupted.assigns.chat_token == nil

      # Both shapes a killed turn can still deliver: a result it sent before the
      # kill landed, and the exit of a task no later turn superseded. Each is
      # identified by what it carries -- a token that no longer matches, an exit
      # while no turn is running -- not by having turned up late.
      stale = {:ok, {socket.assigns.chat_token, {:ok, "Stale answer", []}}}
      assert {:noreply, ^interrupted} = Show.handle_async(:chat_turn, stale, interrupted)

      assert {:noreply, ^interrupted} =
               Show.handle_async(:chat_turn, {:exit, :killed}, interrupted)

      assert Enum.map(Conversations.load(document.id).messages, & &1.role) == ["user"]
    end
  end

  describe "chat with document without embeddings" do
    test "shows not ready message when embeddings are not ready", %{conn: conn} do
      # Create a document without embeddings
      document = create_document_without_embeddings()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat
      view |> element("#toggle-chat") |> render_click()

      # Should show chat panel but no input form (not ready)
      assert has_element?(view, "#chat-messages")
      refute has_element?(view, "#chat-form")
    end
  end

  describe "sending chat messages" do
    setup do
      document = completed_document_with_embedding_fixture()
      %{document: document}
    end

    test "a submitted question is answered by the turn it starts", %{
      conn: conn,
      document: document
    } do
      question = "What is this document about?"

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat panel
      view |> element("#toggle-chat") |> render_click()

      view |> form("#chat-form", %{message: question}) |> render_submit()

      # The question is streamed in by the event itself, so this holds however
      # far the turn behind it has got.
      assert render(view) =~ question

      await_chat_turn(view)

      html = render(view)
      assert html =~ question
      assert html =~ "This is a mock response to your question about"

      # The rendered text alone would not prove the turn landed: the stub streams
      # its answer in deltas, so it is on screen while the turn is still running.
      # The saved message is what only a completed turn produces.
      assert %{messages: messages} = Conversations.load(document.id)
      assert [%{role: "user"}, %{role: "assistant", content: answer}] = messages
      assert answer =~ "This is a mock response to your question about"
      assert answer =~ question

      assigns = :sys.get_state(view.pid).socket.assigns
      refute assigns.chat_loading
      assert assigns.chat_token == nil
    end

    # The chat panel answers in the first person, so a failure the message
    # catalog cannot name is the assistant's apology -- not the neutral fallback
    # a flash would show for the same reason.
    test "a failed turn without a message of its own answers with the apology", %{
      conn: conn,
      document: document
    } do
      Mox.stub(Doctrans.Processing.OpenAIMock, :chat_stream, fn _messages, _on_delta, _opts ->
        {:error, :circuit_open}
      end)

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()
      view |> form("#chat-form", %{message: "What is this document about?"}) |> render_submit()
      await_chat_turn(view)

      apology = "Sorry, I encountered an error. Please try again."
      assert render(view) =~ apology

      assert %{messages: [%{role: "user"}, %{role: "error", content: ^apology}]} =
               Conversations.load(document.id)
    end

    test "a failed turn with a message of its own is not apologised for", %{
      conn: conn,
      document: document
    } do
      Mox.stub(Doctrans.Processing.OpenAIMock, :chat_stream, fn _messages, _on_delta, _opts ->
        {:error, :incomplete_output}
      end)

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()
      view |> form("#chat-form", %{message: "What is this document about?"}) |> render_submit()
      await_chat_turn(view)

      html = render(view)
      assert html =~ "did not return complete final text"
      refute html =~ "Sorry, I encountered an error"
    end

    test "empty message is not submitted", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat panel
      view |> element("#toggle-chat") |> render_click()

      # Submit empty message
      view
      |> form("#chat-form", %{message: ""})
      |> render_submit()

      # Chat input should still be present (no error, just ignored)
      assert has_element?(view, "#chat-input")
      assert_no_chat_turn(view, document)
    end

    # Reproduces #267: the question is saved before the model is called, so a
    # question of any size was a row of any size, pulled into every later mount.
    test "an oversized question is refused with a flash and starts no turn", %{
      conn: conn,
      document: document
    } do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      oversized = String.duplicate("a", Doctrans.Validation.max_chat_question_bytes() + 1)
      view |> form("#chat-form", %{message: oversized}) |> render_submit()

      assert has_element?(view, "#flash-error", "Question too long")
      assert has_element?(view, "#chat-input")
      assert_no_chat_turn(view, document)
    end

    test "a question at the bound is accepted", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      question = String.duplicate("a", Doctrans.Validation.max_chat_question_bytes())
      view |> form("#chat-form", %{message: question}) |> render_submit()
      await_chat_turn(view)

      refute has_element?(view, "#flash-error")

      assert [%{role: "user", content: ^question}, %{role: "assistant"}] =
               Conversations.load(document.id).messages
    end

    test "whitespace-only message is not submitted", %{conn: conn, document: document} do
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # Open chat panel
      view |> element("#toggle-chat") |> render_click()

      # Submit whitespace-only message
      view
      |> form("#chat-form", %{message: "   "})
      |> render_submit()

      # Chat input should still be present
      assert has_element?(view, "#chat-input")
      assert_no_chat_turn(view, document)
    end
  end

  describe "Markdown tables in chat answers" do
    setup do
      %{document: completed_document_with_embedding_fixture()}
    end

    # Answers quote OCR'd tables back verbatim, so the chat path must render the
    # same header/delimiter/body shape the viewer does.
    @answer_table """
    Here are the balances I found:

    | Account     | Debit    | Credit |
    | :---        | ---:     | :---:  |
    | Cash        | 1,234.50 | 0.00   |
    | Receivables | 98.00    | 12.00  |
    """

    test "renders an assistant answer's Markdown table as table elements", %{
      conn: conn,
      document: document
    } do
      question = Conversations.start_question(document.id, "What are the balances?")

      {:ok, answer, _} =
        Conversations.finish(question, "assistant", @answer_table, RetrievedContext.new())

      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      message = "#chat_messages-#{answer.id} .markdown"
      assert has_element?(view, "#{message} table thead th", "Account")
      assert has_element?(view, "#{message} table tbody td", "Receivables")
      assert has_element?(view, "#{message} table tbody td", "1,234.50")
      refute has_element?(view, "#{message} p", "| Account")
    end

    test "renders answer blocks as direct children of the markdown container", %{
      conn: conn,
      document: document
    } do
      # Same edge-margin contract as the viewer: `.markdown > :first-child` in app.css
      # only matches when nothing wraps the rendered Markdown.
      question = Conversations.start_question(document.id, "What are the balances?")

      {:ok, answer, _} =
        Conversations.finish(question, "assistant", @answer_table, RetrievedContext.new())

      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      message = "#chat_messages-#{answer.id} .markdown"
      assert has_element?(view, "#{message} > p", "Here are the balances")
      assert has_element?(view, "#{message} > table tbody td", "Receivables")
    end

    test "renders a table in the still-streaming answer, not just the finalized one" do
      # `#chat-streaming` is the third `.markdown` container and shares
      # `markdown_content/1` with the finalized path, but renders partial Markdown.
      # Rendered as a component: deltas only apply while a turn is in flight, and
      # driving the real submit path races the async turn resetting the assign.
      partial = "Here are the balances:\n\n| Account | Debit |\n"

      assigns = %{
        chat_messages: [],
        chat_loading: true,
        chat_streaming_content: partial,
        embeddings_ready: true
      }

      document = render_panel(assigns)

      # A header row with no delimiter row yet is not a table.
      assert Enum.empty?(LazyHTML.query(document, "#chat-streaming .markdown table"))

      completed =
        %{
          assigns
          | chat_streaming_content: partial <> "| --- | ---: |\n| Receivables | 1,234.50 |\n"
        }

      document = render_panel(completed)

      streaming = "#chat-streaming .markdown"

      assert LazyHTML.query(document, "#{streaming} > p") |> Enum.map(&LazyHTML.text/1) == [
               "Here are the balances:"
             ]

      assert LazyHTML.query(document, "#{streaming} table thead th")
             |> Enum.map(&LazyHTML.text/1) == ["Account", "Debit"]

      assert LazyHTML.query(document, "#{streaming} table tbody td[align='right']")
             |> Enum.map(&LazyHTML.text/1) == ["1,234.50"]
    end

    test "carries the answer table's column alignment into the rendered cells", %{
      conn: conn,
      document: document
    } do
      question = Conversations.start_question(document.id, "What are the balances?")

      {:ok, answer, _} =
        Conversations.finish(question, "assistant", @answer_table, RetrievedContext.new())

      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      message = "#chat_messages-#{answer.id} .markdown"
      assert has_element?(view, "#{message} table thead th[align='right']", "Debit")
      assert has_element?(view, "#{message} table tbody td[align='right']", "1,234.50")
      assert has_element?(view, "#{message} table thead th[align='center']", "Credit")
      assert has_element?(view, "#{message} table tbody td[align='left']", "Cash")
    end

    test "sanitizes answer table cells while keeping alignment and structure", %{
      conn: conn,
      document: document
    } do
      unsafe = """
      | Item | Amount |
      | :--- | ---:   |
      | <script>alert('xss')</script>Widget | 1,234.50 |
      | <span onclick="alert('xss')">Gadget</span> | 88.00 |
      """

      question = Conversations.start_question(document.id, "What did the invoice say?")

      {:ok, answer, _} =
        Conversations.finish(question, "assistant", unsafe, RetrievedContext.new())

      {:ok, view, _} = live(conn, ~p"/documents/#{document.id}")
      view |> element("#toggle-chat") |> render_click()

      message = "#chat_messages-#{answer.id} .markdown"
      assert has_element?(view, "#{message} table tbody td", "Widget")
      assert has_element?(view, "#{message} table tbody td[align='right']", "1,234.50")
      refute has_element?(view, "#{message} script")
      refute has_element?(view, "#{message} [onclick]")
    end
  end

  # Helper functions

  defp assert_no_chat_turn(view, document) do
    assert Conversations.load(document.id).messages == []
    refute has_element?(view, "#chat-streaming")
    # An idle turn renders the same as a finished one; the token is the difference.
    assigns = :sys.get_state(view.pid).socket.assigns
    refute assigns.chat_loading
    assert assigns.chat_token == nil
  end

  # A chat turn is a `start_async/3` task, so `render_async/2` waits on it: it
  # monitors the task and returns once it has exited, by which time its result
  # is already ahead of the next round trip to the LiveView. Nothing holds the
  # turn open -- the stubs answer at once, and these tests are about the turn
  # having landed, not about its in-flight state, which `CrossTabTest` observes
  # through `EmbeddingMocks.hold/2` -- so the task may already have finished by
  # the time this looks, which is covered the same way. Waiting at all is also
  # what keeps the task from outliving the test and querying the database with
  # no sandbox owner.
  defp await_chat_turn(view), do: render_async(view, 2_000)

  defp passages(context), do: RetrievedContext.passages(context)

  defp render_panel(assigns) do
    ChatComponents.chat_panel(assigns) |> rendered_to_string() |> LazyHTML.from_fragment()
  end

  defp create_document_without_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Test Document",
        original_filename: "test.pdf",
        source_language: "en",
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
