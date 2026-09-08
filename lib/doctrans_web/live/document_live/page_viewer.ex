defmodule DoctransWeb.DocumentLive.PageViewer do
  @moduledoc "Page selection, zoom state, and controls for the document viewer."
  use DoctransWeb, :html

  alias Doctrans.Documents

  @doc "Initializes the first page and display settings."
  def init(socket) do
    socket
    |> goto_page(1)
    |> assign(:show_original, false)
    |> assign(:zoom_level, 100)
  end

  def apply_params(socket, %{"page" => page_str}) do
    case Integer.parse(page_str) do
      {page_number, _} ->
        max_page = socket.assigns.document.total_pages || 1
        page_number = max(1, min(page_number, max_page))
        goto_page(socket, page_number)

      :error ->
        socket
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
      {page_number, _} -> {:noreply, goto_page(socket, page_number)}
      :error -> {:noreply, socket}
    end
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

  defp goto_page(socket, page_number) do
    document = socket.assigns.document
    page = Documents.get_page_by_number(document.id, page_number)

    socket
    |> assign(:current_page_number, page_number)
    |> assign(:current_page, page)
  end

  attr :zoom_level, :integer, required: true

  def zoom_controls(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <button
        type="button"
        id="zoom-out"
        phx-click="zoom_out"
        class="btn btn-ghost btn-xs"
        disabled={@zoom_level <= 50}
      >
        <.icon name="hero-minus" class="w-4 h-4" />
      </button>
      <span class="text-xs w-12 text-center">{@zoom_level}%</span>
      <button
        type="button"
        id="zoom-in"
        phx-click="zoom_in"
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
    <footer class="flex items-center justify-center gap-4 px-4 py-3 border-t border-base-300 bg-base-200">
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
