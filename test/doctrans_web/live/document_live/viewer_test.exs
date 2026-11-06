defmodule DoctransWeb.DocumentLive.ViewerTest do
  @moduledoc """
  `Viewer`'s answers about a broadcast, on a bare socket: what a document
  update changed, where a page update landed, and that a burst arms the
  status refresh once.
  """
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Lifecycle
  alias Doctrans.Processing.Run
  alias DoctransWeb.DocumentLive.Viewer
  alias Phoenix.LiveView.Socket

  defp mounted(document) do
    Viewer.init(%Socket{assigns: %{__changed__: %{}}}, document)
  end

  describe "document_updated/2" do
    test "the broadcast row replaces the one on screen and the status is re-read" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      socket = mounted(document)
      assert socket.assigns.processing_status.content == :idle

      {:ok, updated} = Documents.set_total_pages(document, 3)
      assert {:changed, socket} = Viewer.document_updated(socket, updated)

      assert socket.assigns.document.total_pages == 3
      assert socket.assigns.processing_status.pages.expected == 3
    end

    test "a document holding a new run answers run_replaced" do
      document = document_fixture(%{status: "completed", total_pages: 1})
      completed_page_fixture(document)
      socket = mounted(document)

      {:ok, requeued} = Lifecycle.requeue(document, Run.new_attrs())
      assert {:run_replaced, socket} = Viewer.document_updated(socket, requeued)

      assert socket.assigns.document.processing_run_id == requeued.processing_run_id
      assert socket.assigns.processing_status.content == :queued
    end

    test "the current page is resolved against the new row" do
      document = document_fixture(%{status: "completed", total_pages: 3})
      socket = mounted(document) |> Viewer.goto_page(3)
      assert socket.assigns.current_page_number == 3

      # The run was replaced and the page count cleared: there is no page 3 to
      # keep, so the viewer is pinned to page 1.
      {:ok, requeued} = Lifecycle.requeue(document, Run.new_attrs())
      assert {:run_replaced, socket} = Viewer.document_updated(socket, requeued)
      assert socket.assigns.current_page_number == 1
    end
  end

  describe "document_deleted/1" do
    test "answers vanished and clears the document" do
      socket = mounted(document_fixture())

      assert {:vanished, socket} = Viewer.document_deleted(socket)
      assert socket.assigns.document == nil
    end
  end

  describe "page_updated/2" do
    test "the page on screen is re-read, another page of the document is not" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      socket = mounted(document)
      assert socket.assigns.current_page == nil

      first = completed_page_fixture(document, %{page_number: 1})
      second = completed_page_fixture(document, %{page_number: 2})

      assert {:off_screen, socket} = Viewer.page_updated(socket, second)
      assert socket.assigns.current_page == nil

      assert {:on_screen, socket} = Viewer.page_updated(socket, first)
      assert socket.assigns.current_page.id == first.id
    end

    test "a page of another document, or one after the document has gone, is foreign" do
      socket = mounted(document_fixture(%{status: "processing", total_pages: 1}))
      foreign = completed_page_fixture(document_fixture(%{status: "processing", total_pages: 1}))

      assert {:foreign, ^socket} = Viewer.page_updated(socket, foreign)
      refute socket.assigns.status_refresh_pending

      {:vanished, gone} = Viewer.document_deleted(socket)
      own = completed_page_fixture(socket.assigns.document)
      assert {:foreign, ^gone} = Viewer.page_updated(gone, own)
    end

    test "a burst of pages arms the status refresh once, and the landing re-reads it" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      socket = mounted(document)
      first = completed_page_fixture(document, %{page_number: 1})
      second = completed_page_fixture(document, %{page_number: 2})

      {:on_screen, socket} = Viewer.page_updated(socket, first)
      {:off_screen, socket} = Viewer.page_updated(socket, second)
      assert socket.assigns.status_refresh_pending

      assert_receive :refresh_status, 500
      refute_receive :refresh_status, 200

      socket = Viewer.refresh_pending(socket)
      refute socket.assigns.status_refresh_pending
      assert socket.assigns.processing_status.pages.translated == 2
    end
  end
end
