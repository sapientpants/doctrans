defmodule DoctransWeb.DocumentLive.ProgressiveViewerTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.Topics

  test "shows a page created after mount without navigation", %{conn: conn} do
    document = document_fixture(%{total_pages: 1})
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    refute has_element?(view, "img[alt='Page image']")
    refute has_element?(view, ".prose")

    page = completed_page_fixture(document)
    Topics.broadcast_page_update(page)

    assert has_element?(view, "img[src='/uploads/#{page.image_path}']")
    assert has_element?(view, ".prose h1", "Translated Content")
    assert has_element?(view, "#page-selector option[value='1'][selected]")
  end

  test "shows a page created after selecting a missing page", %{conn: conn} do
    document = document_fixture(%{total_pages: 2})
    completed_page_fixture(document)
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    view |> element("#next-page") |> render_click()
    refute has_element?(view, "img[alt='Page image']")
    refute has_element?(view, ".prose")

    page = completed_page_fixture(document, %{page_number: 2, image_path: "page_2.png"})
    Topics.broadcast_page_update(page)

    assert has_element?(view, "img[src='/uploads/#{page.image_path}']")
    assert has_element?(view, ".prose h1", "Translated Content")
    assert has_element?(view, "#page-selector option[value='2'][selected]")
  end

  test "ignores other page numbers and documents in empty and populated viewers", %{conn: conn} do
    document = document_fixture(%{total_pages: 2})
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
    other_page = completed_page_fixture(document, %{page_number: 2, image_path: "other.png"})
    foreign_page = completed_page_fixture(document_fixture())

    Topics.broadcast_page_update(other_page)
    send(view.pid, {:page_updated, foreign_page})

    refute has_element?(view, "img[alt='Page image']")
    refute has_element?(view, ".prose")

    page = completed_page_fixture(document)
    Topics.broadcast_page_update(page)
    assert has_element?(view, "img[src='/uploads/#{page.image_path}']")

    Topics.broadcast_page_update(other_page)
    send(view.pid, {:page_updated, foreign_page})

    assert has_element?(view, "img[src='/uploads/#{page.image_path}']")
    refute has_element?(view, "img[src='/uploads/#{other_page.image_path}']")
    refute has_element?(view, "img[src='/uploads/#{foreign_page.image_path}']")
    assert has_element?(view, "#page-selector option[value='1'][selected]")
  end
end
