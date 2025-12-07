defmodule DoctransWeb.DocumentLive.ShowTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents

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

      assert render(view) =~ "Original Markdown"
    end

    test "zoom in increases zoom level", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "100%"

      view |> element("button[phx-click='zoom_in']") |> render_click()

      assert render(view) =~ "125%"
    end

    test "zoom out decreases zoom level", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert render(view) =~ "100%"

      view |> element("button[phx-click='zoom_out']") |> render_click()

      assert render(view) =~ "75%"
    end

    test "zoom does not exceed 200%", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Click zoom in 4 times (100 -> 125 -> 150 -> 175 -> 200)
      for _ <- 1..4 do
        view |> element("button[phx-click='zoom_in']") |> render_click()
      end

      assert render(view) =~ "200%"
      # Zoom in button should now be disabled
      assert has_element?(view, "button[phx-click='zoom_in'][disabled]")
    end

    test "zoom does not go below 50%", %{conn: conn} do
      doc = document_with_pages_fixture(%{}, 1)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc.id}")

      # Click zoom out 2 times (100 -> 75 -> 50)
      for _ <- 1..2 do
        view |> element("button[phx-click='zoom_out']") |> render_click()
      end

      assert render(view) =~ "50%"
      # Zoom out button should now be disabled
      assert has_element?(view, "button[phx-click='zoom_out'][disabled]")
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
      Documents.broadcast_document_update(updated_doc)

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

      Documents.broadcast_page_update(updated_page)

      # Toggle to original to see the content
      view |> element("input[type='checkbox']") |> render_click()

      assert render(view) =~ "PubSub Updated Content"
    end
  end
end
