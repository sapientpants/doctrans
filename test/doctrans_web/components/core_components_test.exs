defmodule DoctransWeb.CoreComponentsTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
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

  describe "button component" do
    test "renders button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button>Click me</CoreComponents.button>
        """)

      assert html =~ "Click me"
      assert html =~ "<button"
      assert html =~ "btn"
    end

    test "renders button with primary variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button variant="primary">Primary</CoreComponents.button>
        """)

      assert html =~ "btn-primary"
    end

    test "renders link when navigate is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button navigate="/">Home</CoreComponents.button>
        """)

      assert html =~ "Home"
      assert html =~ "href"
    end

    test "renders link when href is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button href="https://example.com">External</CoreComponents.button>
        """)

      assert html =~ ~s(href="https://example.com")
    end

    test "renders disabled button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button disabled>Disabled</CoreComponents.button>
        """)

      assert html =~ "disabled"
    end
  end

  describe "header component" do
    test "renders header with title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>Page Title</CoreComponents.header>
        """)

      assert html =~ "<h1"
      assert html =~ "Page Title"
    end

    test "renders header with subtitle" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>
          Main Title
          <:subtitle>Subtitle text</:subtitle>
        </CoreComponents.header>
        """)

      assert html =~ "Main Title"
      assert html =~ "Subtitle text"
    end

    test "renders header with actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>
          Title
          <:actions>
            <button>Action</button>
          </:actions>
        </CoreComponents.header>
        """)

      assert html =~ "Title"
      assert html =~ "Action"
    end
  end

  describe "table component" do
    test "renders table with rows" do
      assigns = %{
        rows: [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
      }

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="users" rows={@rows}>
          <:col :let={user} label="ID">{user.id}</:col>
          <:col :let={user} label="Name">{user.name}</:col>
        </CoreComponents.table>
        """)

      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ "ID"
      assert html =~ "Name"
    end

    test "renders table with actions" do
      assigns = %{
        rows: [%{id: 1, name: "Alice"}]
      }

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="users" rows={@rows}>
          <:col :let={user} label="Name">{user.name}</:col>
          <:action :let={user}>
            <button>Edit {user.name}</button>
          </:action>
        </CoreComponents.table>
        """)

      assert html =~ "Edit Alice"
    end
  end

  describe "list component" do
    test "renders list with items" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.list>
          <:item title="Name">John Doe</:item>
          <:item title="Email">john@example.com</:item>
        </CoreComponents.list>
        """)

      assert html =~ "Name"
      assert html =~ "John Doe"
      assert html =~ "Email"
      assert html =~ "john@example.com"
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
    test "show returns JS struct" do
      result = CoreComponents.show("#modal")
      assert %JS{} = result
    end

    test "hide returns JS struct" do
      result = CoreComponents.hide("#modal")
      assert %JS{} = result
    end

    test "show with existing JS struct" do
      js = JS.push("event")
      result = CoreComponents.show(js, "#modal")
      assert %JS{} = result
    end

    test "hide with existing JS struct" do
      js = JS.push("event")
      result = CoreComponents.hide(js, "#modal")
      assert %JS{} = result
    end
  end

  describe "translate_error/1" do
    test "translates error message" do
      result = CoreComponents.translate_error({"is required", []})
      assert is_binary(result)
    end

    test "translates error with count" do
      result =
        CoreComponents.translate_error({"should be at least %{count} characters", [count: 5]})

      assert is_binary(result)
    end
  end

  describe "translate_errors/2" do
    test "translates errors for field" do
      errors = [name: {"is required", []}, email: {"is invalid", []}]
      result = CoreComponents.translate_errors(errors, :name)

      assert is_list(result)
      assert length(result) == 1
    end

    test "returns empty list for field without errors" do
      errors = [name: {"is required", []}]
      result = CoreComponents.translate_errors(errors, :email)

      assert result == []
    end
  end
end
