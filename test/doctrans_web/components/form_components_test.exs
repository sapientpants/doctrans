defmodule DoctransWeb.FormComponentsTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "input component" do
    test "renders text input via LiveView", %{conn: conn} do
      # The input component is used in the upload modal
      {:ok, view, _html} = live(conn, ~p"/")

      # Open upload modal which uses form inputs
      view |> element("#upload-document-btn") |> render_click()

      # The upload modal uses select input for target language
      html = render(view)
      assert html =~ "<select"
      assert html =~ "target_language"
    end
  end
end
