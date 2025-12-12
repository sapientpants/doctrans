defmodule DoctransWeb.FormComponentsTest do
  use DoctransWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoctransWeb.FormComponents

  describe "input/1" do
    test "renders text input with name" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "test_input",
          value: "test",
          errors: []
        })

      assert html =~ ~s(name="test_input")
      assert html =~ ~s(value="test")
      assert html =~ ~s(type="text")
    end

    test "renders text input with label" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "test_input",
          label: "Test Label",
          value: "",
          errors: []
        })

      assert html =~ "Test Label"
    end

    test "renders input with custom id" do
      html =
        render_component(&FormComponents.input/1, %{
          id: "custom-id",
          name: "test_input",
          value: "",
          errors: []
        })

      assert html =~ ~s(id="custom-id")
    end

    test "renders input with errors" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "test_input",
          value: "",
          errors: ["is invalid"]
        })

      assert html =~ "is invalid"
      assert html =~ "input-error"
    end

    test "renders email input type" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "email",
          type: "email",
          value: "",
          errors: []
        })

      assert html =~ ~s(type="email")
    end

    test "renders password input type" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "password",
          type: "password",
          value: "",
          errors: []
        })

      assert html =~ ~s(type="password")
    end
  end

  describe "input/1 checkbox" do
    test "renders checkbox input" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "accept",
          type: "checkbox",
          value: true,
          errors: []
        })

      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(name="accept")
    end

    test "renders checkbox with label" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "accept",
          type: "checkbox",
          value: false,
          label: "Accept Terms",
          errors: []
        })

      assert html =~ "Accept Terms"
    end
  end

  describe "input/1 select" do
    test "renders select input" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "country",
          type: "select",
          options: [{"US", "us"}, {"UK", "uk"}],
          value: "us",
          errors: []
        })

      assert html =~ "<select"
      assert html =~ ~s(name="country")
      assert html =~ "US"
      assert html =~ "UK"
    end

    test "renders select with prompt" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "country",
          type: "select",
          options: [{"US", "us"}],
          value: nil,
          prompt: "Select one",
          errors: []
        })

      assert html =~ "Select one"
    end

    test "renders select with label" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "country",
          type: "select",
          options: [{"US", "us"}],
          value: nil,
          label: "Country",
          errors: []
        })

      assert html =~ "Country"
    end
  end

  describe "input/1 textarea" do
    test "renders textarea" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "description",
          type: "textarea",
          value: "some text",
          errors: []
        })

      assert html =~ "<textarea"
      assert html =~ ~s(name="description")
      assert html =~ "some text"
    end

    test "renders textarea with label" do
      html =
        render_component(&FormComponents.input/1, %{
          name: "description",
          type: "textarea",
          value: "",
          label: "Description",
          errors: []
        })

      assert html =~ "Description"
    end
  end
end
