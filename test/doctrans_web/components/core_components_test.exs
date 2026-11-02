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
    # That the op names the element and chains onto an existing command is
    # `Phoenix.LiveView.JS`'s behaviour. What this project authored is the
    # transition each command runs, so that is what is pinned.
    test "show and hide chain onto a command and carry the project's transitions" do
      assert %JS{ops: [["push", %{event: "event"}], ["show", show]]} =
               CoreComponents.show(JS.push("event"), "#modal")

      assert show == %{
               to: "#modal",
               time: 300,
               transition: [
                 ["transition-all", "ease-out", "duration-300"],
                 ["opacity-0", "translate-y-4", "sm:translate-y-0", "sm:scale-95"],
                 ["opacity-100", "translate-y-0", "sm:scale-100"]
               ]
             }

      assert %JS{ops: [["push", %{event: "event"}], ["hide", hide]]} =
               CoreComponents.hide(JS.push("event"), "#modal")

      assert hide == %{
               to: "#modal",
               time: 200,
               transition: [
                 ["transition-all", "ease-in", "duration-200"],
                 ["opacity-100", "translate-y-0", "sm:scale-100"],
                 ["opacity-0", "translate-y-4", "sm:translate-y-0", "sm:scale-95"]
               ]
             }
    end
  end
end
