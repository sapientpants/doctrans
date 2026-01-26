defmodule DoctransWeb.DocumentLive.MarkdownHelpers do
  @moduledoc """
  Shared helpers for rendering and sanitizing Markdown content.

  Used by both ViewerComponents and ChatComponents to ensure consistent
  rendering and security sanitization across the document viewer.
  """

  @doc """
  Renders Markdown text to sanitized HTML.

  Returns an empty string for nil or empty input.
  Sanitizes the output HTML to prevent XSS attacks.

  ## Examples

      iex> render_markdown("**bold**")
      "<p><strong>bold</strong></p>"

      iex> render_markdown(nil)
      ""
  """
  def render_markdown(nil), do: ""
  def render_markdown(""), do: ""

  def render_markdown(text) do
    case Earmark.as_html(text) do
      {:ok, html, _} -> sanitize_html(html)
      {:error, html, _} -> sanitize_html(html)
    end
  end

  @doc """
  Sanitizes HTML to prevent XSS attacks from user-uploaded content.

  Uses HtmlSanitizeEx.basic_html/1 which allows basic formatting tags
  but strips potentially dangerous elements like scripts.
  """
  def sanitize_html(html) do
    HtmlSanitizeEx.basic_html(html)
  end
end
