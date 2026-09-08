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

  ## Options

  - `:hardbreaks` - When `true`, single newlines render as `<br>` instead of being
    collapsed into a space (CommonMark soft breaks). Useful for chat, where the LLM
    separates lines with single newlines and expects them preserved. Defaults to `false`.

  ## Examples

      iex> render_markdown("**bold**")
      "<p><strong>bold</strong></p>"

      iex> render_markdown(nil)
      ""
  """
  def render_markdown(text, opts \\ [])
  def render_markdown(nil, _opts), do: ""
  def render_markdown("", _opts), do: ""

  def render_markdown(text, opts) do
    case MDEx.to_html(text, mdex_options(opts)) do
      {:ok, html} -> sanitize_html(html)
      {:error, html} -> sanitize_html(html)
    end
  end

  defp mdex_options(opts) do
    if Keyword.get(opts, :hardbreaks, false) do
      [render: [hardbreaks: true]]
    else
      []
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
