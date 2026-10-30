defmodule Doctrans.Processing.CancellationErrorsTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Processing.Cancellation
  alias Doctrans.Repo

  import Doctrans.Fixtures
  import ExUnit.CaptureLog

  test "cancel_jobs logs and returns the database exception" do
    document = document_fixture()

    log =
      capture_log(fn ->
        with_unavailable_table("pages", fn ->
          assert {:error, {:database_error, [reason: %Postgrex.Error{} = error]}} =
                   Cancellation.cancel_jobs(document.id)

          assert error.postgres.code == :undefined_table
        end)
      end)

    assert log =~ "Failed to cancel jobs for document #{document.id}"
    assert log =~ "pages"
    assert Documents.get_document!(document.id)
  end

  test "cancel_jobs propagates invalid query arguments" do
    assert_raise Ecto.Query.CastError, fn -> Cancellation.cancel_jobs("invalid-id") end
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
