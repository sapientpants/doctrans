defmodule DoctransWeb.CoreComponentsTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.Component

  alias DoctransWeb.CoreComponents
  alias Phoenix.LiveView.JS

  describe "flash component" do
    test "renders info flash" do
      html =
        render_component(&CoreComponents.flash/1,
          kind: :info,
          flash: %{"info" => "Operation successful"}
        )

      assert html =~ "Operation successful"
      assert html =~ "alert-info"
    end

    test "renders error flash" do
      html =
        render_component(&CoreComponents.flash/1,
          kind: :error,
          flash: %{"error" => "Something went wrong"}
        )

      assert html =~ "Something went wrong"
      assert html =~ "alert-error"
    end

    test "renders flash with title" do
      html =
        render_component(&CoreComponents.flash/1,
          kind: :info,
          title: "Success",
          flash: %{"info" => "Details here"}
        )

      assert html =~ "Success"
      assert html =~ "Details here"
    end

    test "renders nothing when no flash message" do
      html =
        render_component(&CoreComponents.flash/1,
          kind: :info,
          flash: %{}
        )

      refute html =~ "alert"
    end

    test "transient flash carries the auto-dismiss hook and a clearing click" do
      flash =
        render_component(&CoreComponents.flash/1,
          kind: :info,
          flash: %{"info" => "Operation successful"}
        )
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#flash-info")

      assert LazyHTML.attribute(flash, "phx-hook") == ["AutoDismiss"]

      # The hook dismisses by running this command, so it carries the clear.
      assert [phx_click] = LazyHTML.attribute(flash, "phx-click")
      assert phx_click =~ "lv:clear-flash"
    end

    test "non-transient flash has no auto-dismiss hook but still clears its flash on click" do
      flash =
        render_component(&CoreComponents.flash/1,
          kind: :error,
          transient: false,
          flash: %{"error" => "Connection lost"}
        )
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#flash-error")

      assert LazyHTML.attribute(flash, "phx-hook") == []

      # Transience is independent of flash backing, so a dismissal by hand must
      # still clear the server state -- otherwise the next render brings it back.
      assert [phx_click] = LazyHTML.attribute(flash, "phx-click")
      assert phx_click =~ "lv:clear-flash"
    end

    test "flash rendered from its inner block never clears server flash state" do
      assigns = %{}

      flash =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info}>Welcome back!</CoreComponents.flash>
        """)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#flash-info")

      assert LazyHTML.attribute(flash, "phx-hook") == ["AutoDismiss"]
      assert [phx_click] = LazyHTML.attribute(flash, "phx-click")
      refute phx_click =~ "lv:clear-flash"
    end

    test "inner block wins over a flash entry of the same kind without clearing it" do
      assigns = %{flash: %{"info" => "Background job finished"}}

      flash =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info} flash={@flash}>Welcome back!</CoreComponents.flash>
        """)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#flash-info")

      # The inner block is what's on screen, so dismissing must not discard the
      # unrelated flash entry -- the user never saw it.
      assert LazyHTML.text(flash) =~ "Welcome back!"
      refute LazyHTML.text(flash) =~ "Background job finished"
      assert [phx_click] = LazyHTML.attribute(flash, "phx-click")
      refute phx_click =~ "lv:clear-flash"
    end
  end

  describe "icon component" do
    test "renders heroicon" do
      html =
        render_component(&CoreComponents.icon/1,
          name: "hero-x-mark"
        )

      assert html =~ "hero-x-mark"
    end

    test "renders icon with custom class" do
      html =
        render_component(&CoreComponents.icon/1,
          name: "hero-check",
          class: "size-8 text-success"
        )

      assert html =~ "hero-check"
      assert html =~ "size-8 text-success"
    end
  end

  describe "JS commands" do
    test "show targets the requested element" do
      result = CoreComponents.show("#modal")
      assert %JS{ops: [["show", %{to: "#modal"}]]} = result
    end

    test "hide targets the requested element" do
      result = CoreComponents.hide("#modal")
      assert %JS{ops: [["hide", %{to: "#modal"}]]} = result
    end

    test "show with existing JS struct" do
      js = JS.push("event")
      result = CoreComponents.show(js, "#modal")
      assert %JS{ops: [["push", %{event: "event"}], ["show", %{to: "#modal"}]]} = result
    end

    test "hide with existing JS struct" do
      js = JS.push("event")
      result = CoreComponents.hide(js, "#modal")
      assert %JS{ops: [["push", %{event: "event"}], ["hide", %{to: "#modal"}]]} = result
    end
  end

  describe "translate_error/1" do
    test "translates error message" do
      Gettext.with_locale(DoctransWeb.Gettext, "de", fn ->
        assert CoreComponents.translate_error({"can't be blank", []}) == "darf nicht leer sein"
      end)
    end

    test "translates error with count" do
      Gettext.with_locale(DoctransWeb.Gettext, "de", fn ->
        assert CoreComponents.translate_error(
                 {"should be at least %{count} character(s)", [count: 5]}
               ) ==
                 "sollte mindestens 5 Zeichen sein"
      end)
    end
  end
end
