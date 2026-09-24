defmodule DoctransWeb.DocumentLive.StatusPanelTest do
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Page, Topics}
  alias Doctrans.Repo

  @content "#processing-status-content"

  # Oban runs `testing: :inline`, so an insert executes the job then and there
  # and a retry would run a real model call. Both processes have to opt out:
  # `Oban.Config.get_engine/1` reads `self()` *and* `$callers`, and the LiveView
  # names this test among its callers, so setting the mode in only one of them
  # leaves the other voting for inline.
  defp queue_only(view, fun) do
    :sys.replace_state(view.pid, fn state ->
      Process.put(:oban_testing, :manual)
      state
    end)

    Oban.Testing.with_testing_mode(:manual, fun)
  end

  defp index_failure_fixture do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page = completed_page_fixture(document)

    page =
      page |> Page.embedding_changeset(%{embedding_status: "error"}) |> Repo.update!()

    {document, page}
  end

  defp failed_page_fixture do
    document = document_fixture(%{status: "error", total_pages: 2})
    healthy = completed_page_fixture(document)

    failed =
      page_fixture(document, %{
        page_number: 2,
        extraction_status: "completed",
        translation_status: "error"
      })

    {document, healthy, failed}
  end

  describe "reporting the two pipelines apart" do
    test "a completed document whose indexing failed reports the index failure alone", %{
      conn: conn
    } do
      {document, _page} = index_failure_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, ~s{#{@content}[data-content-state="completed"]})
      refute has_element?(view, "#processing-status-failed-pages")

      # Only the indexing half is recoverable here, and that is the whole point:
      # nothing offers to rerun a translation that succeeded.
      assert has_element?(view, "#retry-indexing")
      refute has_element?(view, "#retry-failed-pages")
      refute has_element?(view, "#cancel-processing")
    end

    test "a cancelled document reports the stop and keeps its way back", %{
      conn: conn
    } do
      document = document_fixture(%{status: "cancelled", total_pages: 1})
      _page = completed_page_fixture(document)
      _source = document_source_fixture(document)

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, ~s{#{@content}[data-content-state="cancelled"]})

      # Recovering from a stop must not require deleting the document, so the
      # whole-document reprocess stays available for a cancelled one.
      refute has_element?(view, "#show-document-reprocess[disabled]")
    end
  end

  describe "retrying indexing" do
    test "queues the page again and leaves the translation it already produced", %{conn: conn} do
      {document, page} = index_failure_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      queue_only(view, fn -> view |> element("#retry-indexing") |> render_click() end)

      reloaded = Documents.get_page!(page.id)
      assert reloaded.embedding_status == "pending"
      assert reloaded.translation_status == "completed"
      assert reloaded.translated_markdown == page.translated_markdown
      assert reloaded.extraction_status == "completed"
      assert reloaded.original_markdown == page.original_markdown
      assert reloaded.processing_generation == page.processing_generation

      assert Documents.get_document(document.id).status == "completed"
      assert has_element?(view, "#flash-info")
    end
  end

  # The half that escaped review: both ends of this were tested apart -- the
  # indexer's broadcast and the panel's rendering -- while the wire between them
  # was not, so a run that finished without announcing itself left the panel
  # offering a recovery nothing needed and every test still passed.
  describe "following indexing to its end" do
    test "the panel withdraws the retry once the run reports in", %{conn: conn} do
      {document, page} = index_failure_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      assert has_element?(view, "#retry-indexing")

      indexed =
        page |> Page.embedding_changeset(%{embedding_status: "completed"}) |> Repo.update!()

      Topics.broadcast_page_updated(indexed)

      # The viewer coalesces page updates behind a 100ms timer of its own, so the
      # re-render is genuinely late rather than merely asynchronous.
      Process.sleep(200)

      # The panel itself is asserted alongside the refutation: "no retry button"
      # is also what a panel that failed to render says, and that is the one way
      # this test could pass while reporting nothing.
      assert has_element?(view, "#processing-status")
      refute has_element?(view, "#retry-indexing")
    end
  end

  describe "retrying failed pages" do
    test "names the failed pages and resets only those", %{conn: conn} do
      {document, healthy, failed} = failed_page_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert has_element?(view, ~s{#{@content}[data-content-state="failed"]})
      assert has_element?(view, ~s{#processing-status-failed-count[data-failed-page-count="1"]})
      assert has_element?(view, ~s{#processing-status-failed-pages[data-failed-pages="2"]})

      queue_only(view, fn -> view |> element("#retry-failed-pages") |> render_click() end)

      retried = Documents.get_page!(failed.id)
      assert retried.translation_status == "pending"
      assert retried.processing_generation != failed.processing_generation

      kept = Documents.get_page!(healthy.id)
      assert kept.translation_status == "completed"
      assert kept.translated_markdown == healthy.translated_markdown
      assert kept.processing_generation == healthy.processing_generation

      assert has_element?(view, "#flash-info")
    end
  end

  describe "stopping processing" do
    test "is offered while processing and leaves the document in place", %{conn: conn} do
      document = document_fixture(%{status: "processing", total_pages: 2})
      page = completed_page_fixture(document)
      _pending = page_fixture(document, %{page_number: 2, extraction_status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      assert has_element?(view, "#cancel-processing")

      queue_only(view, fn -> view |> element("#cancel-processing") |> render_click() end)

      stopped = Documents.get_document(document.id)
      assert stopped
      assert stopped.status == "cancelled"
      assert Documents.get_page!(page.id).translated_markdown == page.translated_markdown

      assert has_element?(view, ~s{#{@content}[data-content-state="cancelled"]})
      refute has_element?(view, "#cancel-processing")
    end

    test "is not offered once the document has completed", %{conn: conn} do
      {document, _page} = index_failure_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      refute has_element?(view, "#cancel-processing")
      assert Documents.get_document(document.id).status == "completed"
    end
  end

  # A flash is the tell. Every handler that runs reports its outcome -- info on
  # success, the translated reason on a domain refusal -- so a refused event is
  # the one case that leaves the page with neither.
  describe "refusing an event whose button was not rendered" do
    test "cancel_processing does nothing to a completed document", %{conn: conn} do
      {document, _page} = index_failure_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      queue_only(view, fn -> render_click(view, "cancel_processing", %{}) end)

      assert Documents.get_document(document.id).status == "completed"
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
    end

    test "retry_failed_pages does nothing to a document with no failed page", %{conn: conn} do
      {document, page} = index_failure_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      queue_only(view, fn -> render_click(view, "retry_failed_pages", %{}) end)

      reloaded = Documents.get_page!(page.id)
      assert reloaded.translation_status == "completed"
      assert reloaded.processing_generation == page.processing_generation
      assert Documents.get_document(document.id).status == "completed"
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
    end

    test "retry_indexing does nothing once the index is ready", %{conn: conn} do
      document = completed_document_with_embedding_fixture()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      refute has_element?(view, "#retry-indexing")

      queue_only(view, fn -> render_click(view, "retry_indexing", %{}) end)

      refute has_element?(view, "#flash-info")
      refute has_element?(view, "#flash-error")
    end
  end
end
