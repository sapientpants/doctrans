defmodule DoctransWeb.DocumentLive.PageViewer do
  @moduledoc "Page selection, zoom state, and controls for the document viewer."
  use DoctransWeb, :html

  require Logger

  alias Doctrans.Documents

  @doc "Initializes the first page and display settings."
  def init(socket) do
    socket
    |> goto_page(1)
    |> assign(:show_original, false)
    |> assign(:zoom_level, 100)
    |> assign(:view_tab, :translated)
  end

  def apply_params(socket, %{"page" => page_str}) do
    case Integer.parse(page_str) do
      {page_number, _} -> goto_page(socket, clamp_page(socket, page_number))
      :error -> socket
    end
  end

  def apply_params(socket, _params), do: socket

  def handle_event("prev_page", _params, socket) do
    new_page_number = max(1, socket.assigns.current_page_number - 1)
    {:noreply, goto_page(socket, new_page_number)}
  end

  def handle_event("next_page", _params, socket) do
    max_page = socket.assigns.document.total_pages || 1
    new_page_number = min(max_page, socket.assigns.current_page_number + 1)
    {:noreply, goto_page(socket, new_page_number)}
  end

  def handle_event("goto_page", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page_number, _} -> {:noreply, goto_page(socket, clamp_page(socket, page_number))}
      :error -> {:noreply, socket}
    end
  end

  # Narrow viewports show one panel at a time. The two accepted values are
  # matched literally: the tab arrives from the client, so it must never reach
  # `String.to_atom/1`.
  def handle_event("select_view_tab", %{"tab" => "original"}, socket) do
    {:noreply, assign(socket, :view_tab, :original)}
  end

  def handle_event("select_view_tab", %{"tab" => "translated"}, socket) do
    {:noreply, assign(socket, :view_tab, :translated)}
  end

  def handle_event("select_view_tab", params, socket) do
    # Dropping the value is right -- it arrives from the client -- but dropping
    # it silently also swallows a `phx-value-tab` typo, which then looks like a
    # tab that simply does not respond.
    Logger.warning("select_view_tab ignored unknown tab: #{inspect(params)}")
    {:noreply, socket}
  end

  def handle_event("toggle_original", _params, socket) do
    {:noreply, assign(socket, :show_original, !socket.assigns.show_original)}
  end

  def handle_event("zoom_in", _params, socket) do
    new_zoom = min(200, socket.assigns.zoom_level + 25)
    {:noreply, assign(socket, :zoom_level, new_zoom)}
  end

  def handle_event("zoom_out", _params, socket) do
    new_zoom = max(50, socket.assigns.zoom_level - 25)
    {:noreply, assign(socket, :zoom_level, new_zoom)}
  end

  # `pages.page_number` is an int4: a value past that range makes Postgres raise
  # `numeric_out_of_range` rather than simply miss, taking the LiveView -- and
  # the chat session with it -- down. `apply_params/2` clamped already; the
  # event handler did not, so both now go through here.
  defp clamp_page(socket, page_number) do
    max_page = socket.assigns.document.total_pages || 1
    max(1, min(page_number, max_page))
  end

  defp goto_page(socket, page_number) do
    document = socket.assigns.document
    page = Documents.get_page_by_number(document.id, page_number)

    socket
    |> assign(:current_page_number, page_number)
    |> assign(:current_page, page)
  end

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
    ~H"""
    <div class="flex items-center gap-1">
      <button
        type="button"
        id="zoom-out"
        phx-click="zoom_out"
        aria-label={gettext("Zoom out")}
        class="btn btn-ghost btn-xs"
        disabled={@zoom_level <= 50}
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
        disabled={@zoom_level >= 200}
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
end
