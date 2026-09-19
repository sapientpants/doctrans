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
    test "renders one dispatching button per theme" do
      buttons = LazyHTML.query(render_theme_toggle(), "#theme-toggle button")

      assert LazyHTML.attribute(buttons, "data-phx-theme") == ~w(system light dark)
      assert LazyHTML.attribute(buttons, "id") == ~w(
               theme-toggle-system
               theme-toggle-light
               theme-toggle-dark
             )

      for dispatch <- LazyHTML.attribute(buttons, "phx-click") do
        assert dispatch =~ "phx:set-theme"
      end
    end

    test "names the group and states which option is selected" do
      document = render_theme_toggle()
      group = LazyHTML.query(document, "#theme-toggle")

      # Without these the three unlabelled icon buttons are announced as a bare
      # run of toggles, and the selected one is distinguishable only by the
      # CSS-positioned pill, which assistive technology cannot see.
      assert LazyHTML.attribute(group, "role") == ["group"]
      assert [label] = LazyHTML.attribute(group, "aria-label")
      assert label != ""

      buttons = LazyHTML.query(document, "#theme-toggle button")

      assert LazyHTML.attribute(buttons, "aria-pressed") == ~w(true false false)

      for label <- LazyHTML.attribute(buttons, "aria-label") do
        assert label != ""
      end
    end

    test "hands the pressed state to the client, which is the only side that knows it" do
      # The rendered values above are a placeholder: the choice lives in
      # `localStorage` and never reaches the server. `theme.js` overwrites them
      # before the first paint and the hook restores them after a patch.
      group = LazyHTML.query(render_theme_toggle(), "#theme-toggle")

      assert LazyHTML.attribute(group, "phx-hook") == ["ThemeToggle"]
    end

    test "takes an id, so a page may carry more than one" do
      assigns = %{}

      document =
        rendered_to_string(~H"""
        <Layouts.theme_toggle id="sidebar-theme" />
        """)
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(document, "#sidebar-theme") |> Enum.count() == 1
      assert LazyHTML.attribute(LazyHTML.query(document, "#sidebar-theme button"), "id") == ~w(
               sidebar-theme-system
               sidebar-theme-light
               sidebar-theme-dark
             )
    end
  end

  defp render_theme_toggle do
    assigns = %{}

    rendered_to_string(~H"""
    <Layouts.theme_toggle />
    """)
    |> LazyHTML.from_fragment()
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
