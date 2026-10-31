defmodule DoctransWeb.DocumentLive.ViewerComponents do
  @moduledoc "Components for the document viewer page."
  use DoctransWeb, :html

  import DoctransWeb.DocumentLive.MarkdownHelpers, only: [render_markdown: 1]

  attr :current_page, :integer, required: true
  attr :total_pages, :integer, required: true

  def page_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <form phx-change="goto_page" id="page-selector-form">
        <label for="page-selector" class="sr-only">{gettext("Page")}</label>
        <select id="page-selector" name="page" class="select select-bordered select-sm w-24">
          <option
            :for={page_num <- 1..max(@total_pages, 1)}
            value={page_num}
            selected={page_num == @current_page}
          >
            {page_num}
          </option>
        </select>
      </form>
      <span class="text-sm text-base-content/70">/ {@total_pages}</span>
    </div>
    """
  end

  attr :page, :map, default: nil
  attr :zoom_level, :integer, required: true

  def page_image(assigns) do
    ~H"""
    <div :if={@page && @page.image_path} class="transition-transform">
      <img
        src={"/uploads/#{@page.image_path}"}
        alt={gettext("Page %{number}", number: @page.page_number)}
        class={"shadow-lg rounded transition-transform zoom-#{@zoom_level}"}
      />
    </div>
    <div
      :if={!@page || !@page.image_path}
      class="flex flex-col items-center justify-center h-64 text-base-content/50"
    >
      <.icon name="hero-photo" class="w-16 h-16" />
      <p class="mt-4">{gettext("Page image not available")}</p>
    </div>
    """
  end

  attr :page, :map, default: nil
  attr :show_original, :boolean, required: true

  def page_content(assigns) do
    assigns = assign(assigns, :state, page_state(assigns.page, assigns.show_original))

    ~H"""
    <div id="page-content" data-page-state={@state}>
      <%= case @state do %>
        <% :no_page -> %>
          <div class="flex flex-col items-center justify-center h-64 text-base-content/50">
            <.icon name="hero-document-text" class="w-16 h-16" />
            <p class="mt-4">{gettext("No page selected")}</p>
          </div>
        <% :pending -> %>
          <div class="flex flex-col items-center justify-center h-64 text-base-content/50">
            <.icon name="hero-clock" class="w-16 h-16" />
            <p class="mt-4">{gettext("Waiting to process...")}</p>
          </div>
        <% :extracting -> %>
          <div class="flex flex-col items-center justify-center h-64">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <p class="mt-4 text-base-content/70">{gettext("Extracting text from page...")}</p>
          </div>
        <% :waiting_translation -> %>
          <div class="flex flex-col items-center justify-center h-64 text-base-content/50">
            <.icon name="hero-clock" class="w-16 h-16" />
            <p class="mt-4">{gettext("Waiting to process...")}</p>
          </div>
        <% :translating -> %>
          <div class="flex flex-col items-center justify-center h-64">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <p class="mt-4 text-base-content/70">{gettext("Translating content...")}</p>
          </div>
        <% :error -> %>
          <div class="flex flex-col items-center justify-center h-64 text-error">
            <.icon name="hero-exclamation-triangle" class="w-16 h-16" />
            <p class="mt-4">{gettext("An error occurred processing this page")}</p>
          </div>
        <% :content -> %>
          <div class="markdown markdown-sm">
            <.markdown_content content={get_content(@page, @show_original)} />
          </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Collapses a page's two pipeline statuses and the original/translated toggle
  into the single state the content panel renders.

  The states are mutually exclusive and exhaustive over the four pipeline
  statuses (`pending | processing | completed | error`), so exactly one block
  renders for any page:

    * `:no_page` - nothing selected
    * `:pending` / `:extracting` / `:error` - extraction has not produced text yet
    * `:content` - extraction finished and the original is shown, or the
      translation finished and the translation is shown
    * `:waiting_translation` / `:translating` / `:error` - the translation is
      shown but has not finished

  A translation failure does not hide the original: with the toggle on
  "original", a page whose extraction completed always renders its text.
  """
  @spec page_state(map() | nil, boolean()) ::
          :no_page
          | :pending
          | :extracting
          | :waiting_translation
          | :translating
          | :error
          | :content
  def page_state(nil, _show_original), do: :no_page
  def page_state(%{extraction_status: "pending"}, _show_original), do: :pending
  def page_state(%{extraction_status: "processing"}, _show_original), do: :extracting
  def page_state(%{extraction_status: "error"}, _show_original), do: :error
  def page_state(%{extraction_status: "completed"}, true), do: :content

  def page_state(%{extraction_status: "completed", translation_status: status}, false) do
    case status do
      "pending" -> :waiting_translation
      "processing" -> :translating
      "error" -> :error
      "completed" -> :content
    end
  end

  attr :content, :string, default: nil

  # The HTML comes from MarkdownHelpers.render_markdown/2, which sanitizes before
  # returning; scripts/check_raw_call_sites.exs pins this as a registered raw/1 site.
  # sobelow_skip ["XSS.Raw"]
  def markdown_content(assigns) do
    html = render_markdown(assigns.content || "")
    assigns = assign(assigns, :html, html)
    # No wrapper element: the rendered blocks must be direct children of the
    # `.markdown` container so its edge-margin rules (`.markdown > :first-child`) match.
    ~H"{raw(@html)}"
  end

  defp get_content(page, true), do: page.original_markdown
  defp get_content(page, false), do: page.translated_markdown
end
