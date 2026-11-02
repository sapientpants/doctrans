defmodule DoctransWeb.DocumentLive.ViewerComponents do
  @moduledoc """
  Components for the document viewer page.

  Every control here renders state `DoctransWeb.DocumentLive.PageViewer` owns
  and pushes an event it handles; the two pagers, the zoom buttons and the
  panel tabs all land in the same `handle_event/3`.
  """
  use DoctransWeb, :html

  import DoctransWeb.DocumentLive.MarkdownHelpers, only: [markdown_content: 1]

  alias DoctransWeb.DocumentLive.PageViewer

  @doc """
  Panel switcher for viewports too narrow for the side-by-side split.

  Hidden from `lg:` up, where both panels are visible at once and the tabs
  would describe a choice that no longer exists.

  A pair of toggle buttons in a named group, not `role="tablist"`: the ARIA
  tabs pattern moves between tabs with the arrow keys and takes the unselected
  ones out of the Tab order, which needs a roving `tabindex` this component
  does not maintain. Declaring the role without the behavior tells a screen
  reader user to press keys that do nothing, so the buttons report their
  state with `aria-pressed` and stay ordinary Tab stops instead.

  The two panels are named rather than assumed: each tab points `aria-controls`
  at an element this component does not render, and taking the ids as attrs
  keeps that contract visible at the call site instead of buried in the markup.
  """
  attr :view_tab, :atom, required: true
  attr :show_original, :boolean, required: true
  attr :original_panel_id, :string, default: "original-panel"
  attr :translated_panel_id, :string, default: "translated-panel"

  def view_tabs(assigns) do
    ~H"""
    <div
      id="viewer-tabs"
      role="group"
      aria-label={gettext("Document panels")}
      class="flex items-stretch gap-1 border-b border-base-300 bg-base-200 px-2 lg:hidden"
    >
      <button
        id="view-tab-original"
        type="button"
        phx-click="select_view_tab"
        phx-value-tab="original"
        aria-pressed={to_string(@view_tab == :original)}
        aria-controls={@original_panel_id}
        class={[
          "-mb-px flex-1 border-b-2 px-3 py-2 text-sm font-medium transition-colors",
          "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
          if(@view_tab == :original,
            do: "border-primary text-primary",
            else: "border-transparent text-base-content/70 hover:text-base-content"
          )
        ]}
      >
        {gettext("Original Page")}
      </button>
      <button
        id="view-tab-translated"
        type="button"
        phx-click="select_view_tab"
        phx-value-tab="translated"
        aria-pressed={to_string(@view_tab == :translated)}
        aria-controls={@translated_panel_id}
        class={[
          "-mb-px flex-1 border-b-2 px-3 py-2 text-sm font-medium transition-colors",
          "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
          if(@view_tab == :translated,
            do: "border-primary text-primary",
            else: "border-transparent text-base-content/70 hover:text-base-content"
          )
        ]}
      >
        {content_panel_label(@show_original)}
      </button>
    </div>
    """
  end

  @doc """
  Name of the content panel, which tracks the "Show Original" toggle.

  Shared with the panel's own header in `show.html.heex`: the tab names the
  panel it opens, so a reworded label that only lands in one of the two makes
  the tab point at something that no longer exists under that name.
  """
  def content_panel_label(true), do: gettext("Original Content")
  def content_panel_label(false), do: gettext("Translated Content")

  attr :zoom_level, :integer, required: true

  def zoom_controls(assigns) do
    {min_zoom, max_zoom} = PageViewer.zoom_bounds()
    assigns = assign(assigns, min_zoom: min_zoom, max_zoom: max_zoom)

    ~H"""
    <div class="flex items-center gap-1">
      <button
        type="button"
        id="zoom-out"
        phx-click="zoom_out"
        aria-label={gettext("Zoom out")}
        class="btn btn-ghost btn-xs"
        disabled={@zoom_level <= @min_zoom}
      >
        <.icon name="hero-minus" class="w-4 h-4" />
      </button>
      <span class="text-xs w-12 text-center" aria-live="polite">{@zoom_level}%</span>
      <button
        type="button"
        id="zoom-in"
        phx-click="zoom_in"
        aria-label={gettext("Zoom in")}
        class="btn btn-ghost btn-xs"
        disabled={@zoom_level >= @max_zoom}
      >
        <.icon name="hero-plus" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr :current_page_number, :integer, required: true
  attr :total_pages, :integer, default: nil

  def navigation(assigns) do
    ~H"""
    <footer
      id="page-navigation"
      class="sticky bottom-0 z-10 flex flex-wrap items-center justify-center gap-x-4 gap-y-2 px-4 py-3 border-t border-base-300 bg-base-200 lg:static"
    >
      <button
        type="button"
        id="previous-page"
        phx-click="prev_page"
        class="btn btn-ghost"
        disabled={@current_page_number <= 1}
      >
        <.icon name="hero-chevron-left" class="w-5 h-5" /> {gettext("Previous")}
      </button>

      <span class="text-sm text-base-content/70">
        {gettext("Page %{current} of %{total}",
          current: @current_page_number,
          total: @total_pages || "?"
        )}
      </span>

      <button
        type="button"
        id="next-page"
        phx-click="next_page"
        class="btn btn-ghost"
        disabled={@current_page_number >= (@total_pages || 0)}
      >
        {gettext("Next")} <.icon name="hero-chevron-right" class="w-5 h-5" />
      </button>
    </footer>
    """
  end

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
    <%!-- `data-page-state` is read by the tests alone: it names the branch below
          so an assertion is on the state, not on the prose it renders. --%>
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
          <.markdown_content content={get_content(@page, @show_original)} />
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

  defp get_content(page, true), do: page.original_markdown
  defp get_content(page, false), do: page.translated_markdown
end
