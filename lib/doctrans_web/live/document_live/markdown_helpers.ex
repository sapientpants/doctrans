defmodule DoctransWeb.DocumentLive.MarkdownHelpers do
  @moduledoc """
  Shared helpers for rendering and sanitizing Markdown content.

  Used by both ViewerComponents and ChatComponents to ensure consistent
  rendering and security sanitization across the document viewer. The
  `markdown_content/1` component is the one place the rendered HTML reaches
  the page, so the viewer and the chat cannot sanitize differently.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  require Logger

  alias DoctransWeb.DocumentLive.MarkdownScrubber

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
      {:ok, html} ->
        sanitize_html(html)

      {:error, error} ->
        # MDEx returns an exception struct, not HTML. Rendering must degrade to
        # empty content rather than passing a struct to the sanitizer.
        Logger.warning("Markdown rendering failed: #{Exception.message(error)}")
        ""
    end
  end

  # GFM tables are the one extension enabled: OCR prompts ask the model to keep
  # tables, and without it comrak renders a table as one pipe-delimited paragraph.
  @extensions [table: true]

  defp mdex_options(opts) do
    if Keyword.get(opts, :hardbreaks, false) do
      [extension: @extensions, render: [hardbreaks: true]]
    else
      [extension: @extensions]
    end
  end

  @doc """
  Sanitizes HTML to prevent XSS attacks from user-uploaded content.

  See `DoctransWeb.DocumentLive.MarkdownScrubber` for the allowed tag and
  attribute set, and why it is what it is.
  """
  defdelegate sanitize_html(html), to: MarkdownScrubber, as: :sanitize

  @doc """
  Renders Markdown as a `.markdown` block, styled by `assets/css/app.css`.

  The rendered elements are direct children of that block, which its
  edge-margin rules (`.markdown > :first-child`) rely on.
  """
  attr :content, :string, default: nil

  attr :hardbreaks, :boolean,
    default: false,
    doc: "render single newlines as line breaks; see `render_markdown/2`"

  # The HTML comes from render_markdown/2, which sanitizes before returning;
  # scripts/check_raw_call_sites.exs pins this as the registered raw/1 site.
  # sobelow_skip ["XSS.Raw"]
  def markdown_content(assigns) do
    html = render_markdown(assigns.content || "", hardbreaks: assigns.hardbreaks)
    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="markdown">{raw(@html)}</div>
    """
  end
end
