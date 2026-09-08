defmodule DoctransWeb.DocumentLive.MarkdownHelpersTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.DocumentLive.MarkdownHelpers

  describe "render_markdown/2" do
    test "returns empty string for nil and empty input" do
      assert MarkdownHelpers.render_markdown(nil) == ""
      assert MarkdownHelpers.render_markdown("") == ""
    end

    test "renders basic markdown" do
      assert MarkdownHelpers.render_markdown("**bold**") =~ "<strong>bold</strong>"
    end

    test "collapses single newlines by default (CommonMark soft breaks)" do
      html = MarkdownHelpers.render_markdown("line one\nline two")
      refute html =~ "<br"
    end

    test "renders single newlines as hard breaks when :hardbreaks is set" do
      html = MarkdownHelpers.render_markdown("line one\nline two", hardbreaks: true)
      assert html =~ "<br"
    end

    test "sanitizes dangerous html" do
      html = MarkdownHelpers.render_markdown("<script>alert('x')</script>")
      refute html =~ "<script"
    end
  end
end
