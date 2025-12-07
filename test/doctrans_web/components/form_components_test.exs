defmodule DoctransWeb.FormComponentsTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [to_form: 1]

  alias DoctransWeb.FormComponents

  describe "input component" do
    test "renders text input with label" do
      form = to_form(%{"email" => ""})

      html =
        render_component(&FormComponents.input/1,
          field: form[:email],
          type: "email",
          label: "Email Address"
        )

      assert html =~ "Email Address"
      assert html =~ ~s(type="email")
      assert html =~ ~s(name="email")
    end

    test "renders text input without label" do
      form = to_form(%{"name" => "test"})

      html =
        render_component(&FormComponents.input/1,
          field: form[:name],
          type: "text"
        )

      assert html =~ ~s(type="text")
      assert html =~ ~s(name="name")
      assert html =~ ~s(value="test")
    end

    test "renders checkbox input" do
      form = to_form(%{"remember_me" => true})

      html =
        render_component(&FormComponents.input/1,
          field: form[:remember_me],
          type: "checkbox",
          label: "Remember me"
        )

      assert html =~ ~s(type="checkbox")
      assert html =~ "Remember me"
      assert html =~ "checked"
    end

    test "renders checkbox input unchecked" do
      form = to_form(%{"remember_me" => false})

      html =
        render_component(&FormComponents.input/1,
          field: form[:remember_me],
          type: "checkbox",
          label: "Remember me"
        )

      assert html =~ ~s(type="checkbox")
      refute html =~ ~s(checked="checked")
    end

    test "renders select input" do
      form = to_form(%{"language" => "en"})

      html =
        render_component(&FormComponents.input/1,
          field: form[:language],
          type: "select",
          label: "Language",
          options: [{"English", "en"}, {"German", "de"}],
          prompt: "Select a language"
        )

      assert html =~ "<select"
      assert html =~ "Language"
      assert html =~ "English"
      assert html =~ "German"
      assert html =~ "Select a language"
    end

    test "renders select with multiple" do
      form = to_form(%{"tags" => ["a", "b"]})

      html =
        render_component(&FormComponents.input/1,
          field: form[:tags],
          type: "select",
          options: [{"A", "a"}, {"B", "b"}, {"C", "c"}],
          multiple: true
        )

      assert html =~ ~s(multiple)
      assert html =~ ~s(name="tags[]")
    end

    test "renders textarea" do
      form = to_form(%{"bio" => "Hello world"})

      html =
        render_component(&FormComponents.input/1,
          field: form[:bio],
          type: "textarea",
          label: "Bio"
        )

      assert html =~ "<textarea"
      assert html =~ "Bio"
      assert html =~ "Hello world"
    end

    test "renders password input" do
      form = to_form(%{"password" => ""})

      html =
        render_component(&FormComponents.input/1,
          field: form[:password],
          type: "password",
          label: "Password"
        )

      assert html =~ ~s(type="password")
      assert html =~ "Password"
    end

    test "renders with custom class" do
      form = to_form(%{"name" => ""})

      html =
        render_component(&FormComponents.input/1,
          field: form[:name],
          type: "text",
          class: "custom-class"
        )

      assert html =~ "custom-class"
    end

    test "renders via LiveView integration", %{conn: conn} do
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
