defmodule DoctransWeb.DocumentLive.MarkdownHelpersTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.DocumentLive.MarkdownHelpers

  describe "sanitize_html/1" do
    test "removes executable elements, including nested frames, and preserves safe formatting" do
      html = """
      <p><strong>Keep this</strong></p>
      <script>alert('x')</script>
      <iframe src="https://example.com"><iframe srcdoc="<script>alert('x')</script>"></iframe></iframe>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "strong")) == "Keep this"
      assert Enum.empty?(LazyHTML.query(document, "script, iframe"))
    end

    test "strips image event handlers and javascript links while keeping safe links" do
      html = """
      <img src="missing.png" onerror="alert('x')">
      <a href="javascript:alert('x')" onclick="alert('x')">Unsafe</a>
      <a href="https://example.com">Safe</a>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> LazyHTML.from_document()

      assert Enum.empty?(LazyHTML.query(document, "[onerror], [onclick], a[href^='javascript:']"))
      assert LazyHTML.text(LazyHTML.query(document, "a[href='https://example.com']")) == "Safe"
    end
  end

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
