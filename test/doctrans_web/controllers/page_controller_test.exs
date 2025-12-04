defmodule DoctransWeb.PageControllerTest do
  use DoctransWeb.ConnCase

  test "GET / shows dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Doctrans"
    assert html_response(conn, 200) =~ "PDF Book Translator"
  end
end
