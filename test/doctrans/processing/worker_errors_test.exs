defmodule Doctrans.Processing.WorkerErrorsTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker
  alias Doctrans.Repo

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  test "status logs database failures before returning zero counts" do
    log =
      capture_log(fn ->
        with_unavailable_table("oban_jobs", fn ->
          assert Worker.status() == %{
                   pdf_extraction: 0,
                   llm_processing: 0,
                   embedding_generation: 0,
                   health_check: 0
                 }
        end)
      end)

    assert log =~ "Failed to read Oban queue status"
    assert log =~ "oban_jobs"
  end

  test "status propagates unexpected runtime errors" do
    config = Application.fetch_env!(:doctrans, Oban)
    Application.put_env(:doctrans, Oban, Keyword.put(config, :repo, __MODULE__))
    on_exit(fn -> Application.put_env(:doctrans, Oban, config) end)

    assert_raise RuntimeError, "unexpected aggregate bug", &Worker.status/0
  end

  test "cancellation logs and returns the database exception" do
    document = document_fixture()

    log =
      capture_log(fn ->
        with_unavailable_table("pages", fn ->
          assert {:error, {:database_error, [reason: %Postgrex.Error{} = error]}} =
                   Worker.cancel_document(document.id)

          assert error.postgres.code == :undefined_table
        end)
      end)

    assert log =~ "Failed to cancel jobs for document #{document.id}"
    assert log =~ "pages"
    assert Documents.get_document!(document.id)
  end

  test "cancellation propagates invalid query arguments" do
    assert_raise Ecto.Query.CastError, fn -> Worker.cancel_document("invalid-id") end
  end

  test "successful cancellation cancels document and page jobs only for the selected document" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture()
      page = page_fixture(document)
      other_document = document_fixture()
      {:ok, extraction} = Worker.process_document(document.id, "/tmp/document.pdf")
      {:ok, processing} = Worker.queue_page(page.id)
      {:ok, other} = Worker.process_document(other_document.id, "/tmp/other.pdf")

      assert :ok = Worker.cancel_document(document.id)
      assert Repo.get!(Oban.Job, extraction.id).state == "cancelled"
      assert Repo.get!(Oban.Job, processing.id).state == "cancelled"
      assert Repo.get!(Oban.Job, other.id).state == "available"
    end)
  end

  test "failed cancellation preserves the document and shows a deletion error", %{conn: conn} do
    document = document_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    capture_log(fn ->
      with_unavailable_table("pages", fn ->
        view
        |> element("#documents-#{document.id} button[phx-click='delete_document']")
        |> render_click()

        assert has_element?(view, "#flash-error", "Failed to delete document")
        assert has_element?(view, "#documents-#{document.id}")
        refute has_element?(view, "#flash-info", "Document deleted successfully")
      end)
    end)

    assert Documents.get_document!(document.id)
  end

  # Used as the configured status repository to simulate a programming error.
  def aggregate(_query, :count, :id), do: raise("unexpected aggregate bug")

  defp with_unavailable_table(table, fun) do
    Repo.query!("ALTER TABLE #{table} RENAME TO unavailable_#{table}")

    try do
      fun.()
    after
      # The SQL sandbox isolates each query failure with its own savepoint.
      Repo.query!("ALTER TABLE unavailable_#{table} RENAME TO #{table}")
    end
  end
end
