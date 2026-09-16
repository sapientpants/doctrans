defmodule DoctransWeb.DocumentLive.ShowTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics

  describe "missing documents" do
    test "renders a missing document on HTTP load and connected mount", %{conn: conn} do
      conn = get(conn, ~p"/documents/#{Uniq.UUID.uuid7()}?page=2&from=search&q=test")

      assert html_response(conn, 200)
             |> LazyHTML.from_document()
             |> LazyHTML.query("#document-not-found")
             |> LazyHTML.to_tree() != []

      {:ok, view, _html} = live(conn)

      assert has_element?(view, "#document-not-found h1", "Document not found")
      refute has_element?(view, "#page-selector")
      assert has_element?(view, "#document-not-found-home[href='/']")
      view |> element("#document-not-found-home") |> render_click()
      assert_redirect(view, ~p"/")
    end

    # U11 broadcasts deletions to the per-document topic this viewer subscribes to,
    # so a document deleted from the dashboard while it is open must fall back to
    # the not-found branch instead of rendering against a row that is gone.
    test "a deletion while the viewer is open renders the not-found branch", %{conn: conn} do
      document = document_with_pages_fixture(%{title: "Open Elsewhere"}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      refute has_element?(view, "#document-not-found")

      {:ok, _} = Documents.delete_document(document)

      assert has_element?(view, "#document-not-found h1", "Document not found")
      assert has_element?(view, "#document-not-found-home[href='/']")
      refute has_element?(view, "#page-selector")

      # Still answering events rather than having crashed on the missing row.
      render_click(view, "next_page")
      assert has_element?(view, "#document-not-found")
    end

    # `Worker.cancel_document/1` does not stop an Oban job that is already
    # executing, so a job working on the deleted document can still broadcast on
    # `document:<id>` after `{:document_deleted, _}` has emptied the assign.
    test "a document update arriving after the deletion leaves the viewer standing", %{conn: conn} do
      document = document_with_pages_fixture(%{title: "Open Elsewhere"}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # The nil state is reached the way it is in production: through the real
      # deletion broadcast, not by assigning it here.
      {:ok, deleted} = Documents.delete_document(document)
      assert has_element?(view, "#document-not-found")

      Topics.broadcast_document_updated(deleted)

      assert has_element?(view, "#document-not-found h1", "Document not found")
      assert Process.alive?(view.pid)
    end

    test "renders malformed and deleted document IDs safely", %{conn: conn} do
      document = document_fixture()
      {:ok, _} = Documents.delete_document(document)

      for id <- ["invalid", document.id] do
        {:ok, view, _html} = live(conn, ~p"/documents/#{id}")
        assert has_element?(view, "#document-not-found")
        render_click(view, "next_page")
        assert has_element?(view, "#document-not-found")
      end
    end
  end

  describe "Show LiveView" do
    test "mounts with document and first page", %{conn: conn} do
      doc = document_with_pages_fixture(%{title: "Test Doc"}, 3)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, "h1", "Test Doc")
      assert render(view) =~ "Page 1 of 3"
    end

    test "displays page navigation controls", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 5)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, "button", "Previous")
      assert has_element?(view, "button", "Next")
      assert has_element?(view, "#page-selector")
    end

    test "navigates to next page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "Page 1 of 3"

      view |> element("button", "Next") |> render_click()

      assert render(view) =~ "Page 2 of 3"
    end

    test "navigates to previous page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}?page=3")

      assert render(view) =~ "Page 3 of 3"

      view |> element("button", "Previous") |> render_click()

      assert render(view) =~ "Page 2 of 3"
    end

    test "prev_page button is disabled on first page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Already at page 1, previous button should be disabled
      assert has_element?(view, "button[disabled]", "Previous")
      assert render(view) =~ "Page 1 of 3"
    end

    test "next_page button is disabled on last page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}?page=3")

      # At last page, next button should be disabled
      assert has_element?(view, "button[disabled]", "Next")
      assert render(view) =~ "Page 3 of 3"
    end

    test "goto_page navigates to specific page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 5)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      view |> element("#page-selector-form") |> render_change(%{page: "3"})

      assert render(view) =~ "Page 3 of 5"
    end

    test "goto_page handles invalid input", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      view |> element("#page-selector-form") |> render_change(%{page: "invalid"})

      # Should stay on current page
      assert render(view) =~ "Page 1 of 3"
    end

    test "toggles show original content", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Default is translated content
      assert render(view) =~ "Translated Content"

      view |> element("input[type='checkbox']") |> render_click()

      assert render(view) =~ "Original Content"
    end

    test "zoom in increases zoom level", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "100%"

      view |> element("#zoom-in") |> render_click()

      assert render(view) =~ "125%"
    end

    test "zoom out decreases zoom level", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "100%"

      view |> element("#zoom-out") |> render_click()

      assert render(view) =~ "75%"
    end

    test "zoom does not exceed 200%", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Click zoom in 4 times (100 -> 125 -> 150 -> 175 -> 200)
      for _ <- 1..4 do
        view |> element("#zoom-in") |> render_click()
      end

      assert render(view) =~ "200%"
      # Zoom in button should now be disabled
      assert has_element?(view, "#zoom-in[disabled]")
    end

    test "zoom does not go below 50%", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Click zoom out 2 times (100 -> 75 -> 50)
      for _ <- 1..2 do
        view |> element("#zoom-out") |> render_click()
      end

      assert render(view) =~ "50%"
      # Zoom out button should now be disabled
      assert has_element?(view, "#zoom-out[disabled]")
    end

    test "displays document status badge", %{conn: conn} do
      doc = document_with_pages_fixture(%{status: "processing"}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, ".badge", "Processing")
    end

    test "displays target language", %{conn: conn} do
      doc = document_with_pages_fixture(%{target_language: "es"}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "Spanish"
    end

    test "back button navigates to index by default", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, "a[href='/']", "Back")
    end

    test "back button navigates to search when from=search", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}?from=search&q=test")

      assert has_element?(view, "a[href='/search?q=test']", "Back")
    end

    test "handles page param in URL", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 5)
      {:ok, _view, html} = live(conn, ~p"/documents/#{doc.id}?page=3")

      assert html =~ "Page 3 of 5"
    end

    test "clamps page param to valid range", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, _view, html} = live(conn, ~p"/documents/#{doc.id}?page=999")

      # Should clamp to max page
      assert html =~ "Page 3 of 3"
    end

    test "clamps negative page param to 1", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, _view, html} = live(conn, ~p"/documents/#{doc.id}?page=-5")

      assert html =~ "Page 1 of 3"
    end

    test "handles invalid page param gracefully", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 3)
      {:ok, _view, html} = live(conn, ~p"/documents/#{doc.id}?page=invalid")

      # Should default to page 1
      assert html =~ "Page 1 of 3"
    end

    test "shows pending state for unprocessed page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "Waiting to process"
    end

    test "shows processing state for extracting page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages
      Documents.update_page_extraction(page, %{extraction_status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "Extracting text from page"
    end

    test "shows translation in progress state", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "test"
        })

      Documents.update_page_translation(page, %{translation_status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "Translating content"
    end

    test "shows error state for failed page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages
      Documents.update_page_extraction(page, %{extraction_status: "error"})

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "An error occurred processing this page"
    end

    test "shows translated content when completed", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Original"
        })

      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated Text Here"
      })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "Translated Text Here"
    end

    test "shows original content when toggled", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Original Text Here"
        })

      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated"
      })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Toggle to original
      view |> element("input[type='checkbox']") |> render_click()

      assert render(view) =~ "Original Text Here"
    end

    test "receives document updates via PubSub", %{conn: conn} do
      doc = document_with_pages_fixture(%{title: "Initial Title"}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Update document and broadcast
      {:ok, updated_doc} = Documents.update_document(doc, %{title: "Updated Title"})
      Topics.broadcast_document_updated(updated_doc)

      # Wait for the message to be processed
      assert render(view) =~ "Updated Title"
    end

    test "receives page updates via PubSub", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      [page] = doc.pages

      # Update page and broadcast
      {:ok, updated_page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# PubSub Updated Content"
        })

      Topics.broadcast_page_updated(updated_page)

      # Toggle to original to see the content
      view |> element("input[type='checkbox']") |> render_click()

      assert render(view) =~ "PubSub Updated Content"
    end
  end

  describe "Markdown tables in the viewer" do
    # Shape an OCR pass produces from a ledger-like page: a header row, a
    # delimiter row declaring per-column alignment, and numeric body rows.
    @translated_table """
    | Account     | Debit    | Credit |
    | :---        | ---:     | :---:  |
    | Cash        | 1,234.50 | 0.00   |
    | Receivables | 98.00    | 12.00  |
    | Total       | 1,332.50 | 12.00  |
    """

    @original_table """
    | Konto       | Soll     | Haben |
    | :---        | ---:     | :---: |
    | Kasse       | 1.234,50 | 0,00  |
    | Forderungen | 98,00    | 12,00 |
    | Summe       | 1.332,50 | 12,00 |
    """

    test "renders a page's Markdown table as table elements in the markdown container", %{
      conn: conn
    } do
      doc = completed_page_document(@original_table, @translated_table)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, ".markdown table thead th", "Account")
      assert has_element?(view, ".markdown table thead th", "Credit")
      assert has_element?(view, ".markdown table tbody td", "Receivables")
      assert has_element?(view, ".markdown table tbody td", "1,234.50")
      refute has_element?(view, ".markdown p", "| Account")
    end

    test "renders the original page's Markdown table as table elements when toggled", %{
      conn: conn
    } do
      doc = completed_page_document(@original_table, @translated_table)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      view |> element("input[type='checkbox']") |> render_click()

      assert has_element?(view, ".markdown table thead th", "Konto")
      assert has_element?(view, ".markdown table tbody td", "Forderungen")
      assert has_element?(view, ".markdown table tbody td", "1.234,50")
      refute has_element?(view, ".markdown table tbody td", "Receivables")
    end

    test "renders markdown blocks as direct children of the markdown container", %{conn: conn} do
      # `.markdown > :first-child` / `> :last-child` in app.css trim the margins at the
      # container edges. A wrapper element around the rendered Markdown makes those
      # rules match the wrapper instead, which restores the space they exist to remove.
      doc = completed_page_document(@original_table, "## Ledger\n\n" <> @translated_table)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, ".markdown > h2", "Ledger")
      assert has_element?(view, ".markdown > table tbody td", "Receivables")
    end

    test "carries the delimiter row's column alignment into the rendered cells", %{conn: conn} do
      doc = completed_page_document(@original_table, @translated_table)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, ".markdown table thead th[align='right']", "Debit")
      assert has_element?(view, ".markdown table tbody td[align='right']", "1,234.50")
      assert has_element?(view, ".markdown table thead th[align='center']", "Credit")
      assert has_element?(view, ".markdown table tbody td[align='left']", "Cash")
    end

    test "sanitizes table cell content while keeping alignment and structure", %{conn: conn} do
      unsafe = """
      | Item | Amount |
      | :--- | ---:   |
      | <script>alert('xss')</script>Widget | 1,234.50 |
      | <span onclick="alert('xss')">Gadget</span> | 88.00 |
      """

      doc = completed_page_document(unsafe, unsafe)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, ".markdown table tbody td", "Widget")
      assert has_element?(view, ".markdown table tbody td[align='right']", "1,234.50")
      refute has_element?(view, ".markdown script")
      refute has_element?(view, ".markdown [onclick]")
    end
  end

  describe "Reprocess functionality" do
    test "shows reprocess button for completed page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Test"
        })

      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated"
      })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, "button[phx-click='show_reprocess_modal']")
    end

    test "shows reprocess button for page with error", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      Documents.update_page_extraction(page, %{extraction_status: "error"})

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert has_element?(view, "button[phx-click='show_reprocess_modal']")
    end

    test "does not show reprocess button for processing page", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      Documents.update_page_extraction(page, %{extraction_status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      refute has_element?(view, "button[phx-click='show_reprocess_modal']")
    end

    test "opens reprocess modal on button click", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Test"
        })

      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated"
      })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      view |> element("button[phx-click='show_reprocess_modal']") |> render_click()

      assert has_element?(view, "#reprocess-modal")
      assert render(view) =~ "Reprocess Page"
    end

    test "closes reprocess modal on cancel", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Test"
        })

      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated"
      })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Open modal
      view |> element("button[phx-click='show_reprocess_modal']") |> render_click()
      assert has_element?(view, "#reprocess-modal")

      # Close modal via Cancel button (btn-ghost)
      view |> element("#reprocess-modal button.btn-ghost", "Cancel") |> render_click()
      refute has_element?(view, "#reprocess-modal")
    end

    test "reprocess modal shows model selection form", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Test"
        })

      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated"
      })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      view |> element("button[phx-click='show_reprocess_modal']") |> render_click()

      # Should show form elements
      assert has_element?(view, "#reprocess-form")
      assert has_element?(view, "#extraction-model-select")
      assert has_element?(view, "#translation-model-select")
      assert has_element?(view, "#reprocess-submit-btn")
    end

    test "reprocess form rejects invalid model selection", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      [page] = doc.pages

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Test"
        })

      {:ok, _page} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "# Translated"
        })

      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Open modal
      view |> element("button[phx-click='show_reprocess_modal']") |> render_click()

      # Submit form directly with invalid models (bypasses form validation)
      # This simulates a malicious request with invalid model names
      render_click(view, "reprocess_page", %{
        "extraction_model" => "nonexistent-model",
        "translation_model" => "another-fake-model"
      })

      # Should show error flash
      assert render(view) =~ "Invalid model selection"
    end
  end

  defp completed_page_document(original_markdown, translated_markdown) do
    doc = document_with_pages_fixture(%{}, 1)
    [page] = doc.pages

    {:ok, page} =
      Documents.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: original_markdown
      })

    {:ok, _page} =
      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: translated_markdown
      })

    doc
  end
end
