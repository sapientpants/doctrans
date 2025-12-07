defmodule DoctransWeb.LayoutsTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component

  alias DoctransWeb.Layouts

  describe "app/1" do
    test "renders main layout with flash" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash}>
          <h1>Test Content</h1>
        </Layouts.app>
        """)

      assert html =~ "<main"
      assert html =~ "Test Content"
    end

    test "renders layout with current_scope" do
      assigns = %{flash: %{}, current_scope: %{user_id: 1}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash} current_scope={@current_scope}>
          Content
        </Layouts.app>
        """)

      assert html =~ "<main"
    end
  end

  describe "flash_group/1" do
    test "renders flash group container" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.flash_group flash={@flash} />
        """)

      assert html =~ "flash-group"
      assert html =~ "client-error"
      assert html =~ "server-error"
    end

    test "renders with custom id" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.flash_group flash={@flash} id="custom-flash" />
        """)

      assert html =~ "custom-flash"
    end
  end

  describe "theme_toggle/1" do
    test "renders theme toggle buttons" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.theme_toggle />
        """)

      assert html =~ "phx:set-theme"
      assert html =~ "data-phx-theme=\"system\""
      assert html =~ "data-phx-theme=\"light\""
      assert html =~ "data-phx-theme=\"dark\""
    end
  end
end
