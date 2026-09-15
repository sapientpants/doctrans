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

    test "connectivity notices render without the auto-dismiss hook" do
      # Regression guard for U06: the hook used to remove these notices from the
      # DOM a few seconds after mount, leaving the `phx-disconnected` handlers
      # with no node to target once the socket actually dropped.
      document = render_flash_group()

      for id <- ["#client-error", "#server-error"] do
        notice = LazyHTML.query(document, id)

        assert LazyHTML.attribute(notice, "phx-hook") == []
        assert [phx_click] = LazyHTML.attribute(notice, "phx-click")
        refute phx_click =~ "lv:clear-flash"
      end
    end

    test "connectivity notices keep their connection handlers and stay hidden until needed" do
      document = render_flash_group()

      for id <- ["#client-error", "#server-error"] do
        notice = LazyHTML.query(document, id)

        assert [disconnected] = LazyHTML.attribute(notice, "phx-disconnected")
        assert disconnected =~ id
        assert [connected] = LazyHTML.attribute(notice, "phx-connected")
        assert connected =~ id
        assert LazyHTML.attribute(notice, "hidden") == [""]
      end
    end

    test "flash-backed notices still auto-dismiss" do
      document = render_flash_group()

      for id <- ["#flash-info", "#flash-error"] do
        notice = LazyHTML.query(document, id)

        assert LazyHTML.attribute(notice, "phx-hook") == ["AutoDismiss"]
        assert [phx_click] = LazyHTML.attribute(notice, "phx-click")
        assert phx_click =~ "lv:clear-flash"
      end
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

  # Renders the flash group with both flash kinds present, so all four notices --
  # the two flash-backed ones and the two connectivity banners -- are in the tree.
  defp render_flash_group do
    assigns = %{flash: %{"info" => "Saved", "error" => "Failed"}}

    rendered_to_string(~H"""
    <Layouts.flash_group flash={@flash} />
    """)
    |> LazyHTML.from_fragment()
  end
end
