defmodule DoctransWeb.DocumentExportControllerTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.Pages

  # The exported scaffolding is fixed English on purpose (see
  # `Doctrans.Documents.Export`), so these assertions name literal strings rather
  # than going through Gettext.
  @failed_note "Not translated: this page failed."
  @pending_note "Not translated yet."
  @empty_note "This document has no pages."

  defp image_path(document, page_number),
    do: "documents/#{document.id}/pages/page_#{page_number}.png"

  defp translated_page(document, page_number, markdown) do
    page =
      page_fixture(document, %{
        page_number: page_number,
        image_path: image_path(document, page_number)
      })

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        extraction_model: "qwen3-vl:8b",
        original_markdown: "Original page #{page_number}"
      })

    {:ok, page} =
      Pages.update_page_translation(page, %{
        translation_status: "completed",
        translation_model: "qwen3:14b",
        translated_markdown: markdown
      })

    page
  end

  defp extracted_page(document, page_number) do
    page =
      page_fixture(document, %{
        page_number: page_number,
        image_path: image_path(document, page_number)
      })

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: "Original page #{page_number}"
      })

    page
  end

  defp failed_page(document, page_number) do
    page =
      page_fixture(document, %{
        page_number: page_number,
        image_path: image_path(document, page_number)
      })

    {:ok, page} = Pages.update_page_extraction(page, %{extraction_status: "error"})

    page
  end

  defp content_disposition(conn) do
    [disposition] = get_resp_header(conn, "content-disposition")
    disposition
  end

  # Phoenix percent-encodes the filename into the header, so decoding it back is
  # what lets a test assert about the name the reader is offered rather than
  # about Phoenix's encoding of it.
  defp downloaded_filename(conn) do
    [_, encoded] = Regex.run(~r/filename="([^"]*)"/, content_disposition(conn))
    URI.decode(encoded)
  end

  describe "GET /documents/:id/export.md" do
    test "sends the translated pages as a markdown attachment", %{conn: conn} do
      document =
        document_fixture(%{title: "Quarterly Report", status: "completed", total_pages: 2})

      translated_page(document, 1, "# Erste Seite\n\nInhalt der ersten Seite.")
      translated_page(document, 2, "# Zweite Seite\n\nInhalt der zweiten Seite.")

      conn = get(conn, ~p"/documents/#{document.id}/export.md")

      body = response(conn, 200)

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/markdown"
      assert content_type =~ "charset=utf-8"

      assert content_disposition(conn) =~ "attachment;"
      assert downloaded_filename(conn) == "Quarterly Report.md"

      assert body =~ "# Quarterly Report"
      assert body =~ "## Page 1"
      assert body =~ "## Page 2"
      assert body =~ "Inhalt der ersten Seite."
      assert body =~ "Inhalt der zweiten Seite."
      refute body =~ @failed_note
      refute body =~ @pending_note
    end

    test "marks a failed page and one that is not translated yet", %{conn: conn} do
      document = document_fixture(%{title: "Partial Run", status: "error", total_pages: 3})
      translated_page(document, 1, "Nur diese Seite ist fertig.")
      failed_page(document, 2)
      extracted_page(document, 3)

      conn = get(conn, ~p"/documents/#{document.id}/export.md")
      body = response(conn, 200)

      # The header counts and the per-page notes come from the same predicates,
      # so both are checked: a body that marks a page failed while the header
      # calls it pending would be the bug worth catching.
      assert body =~ "3 total"
      assert body =~ "1 translated"
      assert body =~ "1 failed"
      assert body =~ "1 not yet translated"

      assert body =~ @failed_note
      assert body =~ @pending_note

      # The note states both stage statuses, so a reader can tell an extraction
      # failure from a translation failure.
      assert body =~ "Extraction: error."
      assert body =~ "Extraction: completed."
    end

    test "offers a filename with no separator, quote, or line break", %{conn: conn} do
      document = document_fixture(%{title: "../../etc/pa\"ss\r\nwd"})

      conn = get(conn, ~p"/documents/#{document.id}/export.md")

      assert response(conn, 200)

      filename = downloaded_filename(conn)

      for unsafe <- ["/", "\\", "\"", "\r", "\n", ".."] do
        refute String.contains?(filename, unsafe)
      end

      assert String.ends_with?(filename, ".md")

      # A CR/LF surviving into the raw header would split the response itself,
      # independently of what the decoded filename looks like.
      refute content_disposition(conn) =~ "\r"
      refute content_disposition(conn) =~ "\n"
    end

    test "renders the empty-document note for a document with no pages", %{conn: conn} do
      document = document_fixture(%{title: "Nothing Here"})

      conn = get(conn, ~p"/documents/#{document.id}/export.md")
      body = response(conn, 200)

      assert body =~ "# Nothing Here"
      assert body =~ @empty_note
    end

    test "answers 404 for a well-formed id that matches no document", %{conn: conn} do
      conn = get(conn, ~p"/documents/#{Uniq.UUID.uuid7()}/export.md")

      assert response(conn, 404) =~ "Not Found"
      assert get_resp_header(conn, "content-disposition") == []
    end

    # A hand-typed URL must not surface as a 500: the lookup casts the id and
    # returns nil, and reaching the assertion at all proves nothing was raised.
    test "answers 404 for an id that is not a UUID", %{conn: conn} do
      conn = get(conn, ~p"/documents/#{"not-a-uuid"}/export.md")

      assert response(conn, 404) =~ "Not Found"
      assert get_resp_header(conn, "content-disposition") == []
    end
  end
end
