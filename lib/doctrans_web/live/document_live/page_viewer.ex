defmodule DoctransWeb.DocumentLive.PageViewer do
  @moduledoc """
  Page selection, zoom and panel state for the document viewer.

  Socket state and the events that change it only; the controls that render
  that state are in `DoctransWeb.DocumentLive.ViewerComponents`, the way
  `ChatSession` and `ChatComponents` divide the chat panel.
  """

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Doctrans.Documents

  # The discrete zoom scale, from the smallest level to the largest in steps of
  # one increment. Every level needs a matching `.zoom-<level>` rule in
  # `assets/css/app.css`: `ViewerComponents.page_image/1` interpolates the class
  # name, so a level with no rule renders the page unscaled and nothing reports
  # it. The bounds are read by `zoom_controls/1` for its disabled buttons, so
  # the controls stop exactly where the clamp does.
  @zoom_min 50
  @zoom_max 200
  @zoom_step 25

  @doc "The zoom level the viewer opens at."
  @spec default_zoom() :: pos_integer()
  def default_zoom, do: 100

  @doc "The smallest and largest zoom level."
  @spec zoom_bounds() :: {pos_integer(), pos_integer()}
  def zoom_bounds, do: {@zoom_min, @zoom_max}

  @doc "Initializes the first page and display settings."
  def init(socket) do
    socket
    |> goto_page(1)
    |> assign(:show_original, false)
    |> assign(:zoom_level, default_zoom())
    |> assign(:view_tab, :translated)
  end

  def apply_params(socket, %{"page" => page_str}) do
    case Integer.parse(page_str) do
      {page_number, _} -> goto_page(socket, page_number)
      :error -> socket
    end
  end

  def apply_params(socket, _params), do: socket

  def handle_event("prev_page", _params, socket) do
    {:noreply, goto_page(socket, socket.assigns.current_page_number - 1)}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, goto_page(socket, socket.assigns.current_page_number + 1)}
  end

  def handle_event("goto_page", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page_number, _} -> {:noreply, goto_page(socket, page_number)}
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
    new_zoom = min(@zoom_max, socket.assigns.zoom_level + @zoom_step)
    {:noreply, assign(socket, :zoom_level, new_zoom)}
  end

  def handle_event("zoom_out", _params, socket) do
    new_zoom = max(@zoom_min, socket.assigns.zoom_level - @zoom_step)
    {:noreply, assign(socket, :zoom_level, new_zoom)}
  end

  @doc """
  Shows `page_number`, clamped to the document's pages.

  Every page change goes through here, whatever asked for it: a URL param, a
  control, or `Show` keeping its place after the document was re-read. The
  clamp is not only for a page that does not exist. `pages.page_number` is an
  int4, and a value past that range makes Postgres raise `numeric_out_of_range`
  rather than simply miss, taking the LiveView -- and the chat session with it
  -- down. A document still counting its pages has none to show, so it pins
  the viewer to page 1.
  """
  def goto_page(socket, page_number) do
    document = socket.assigns.document
    page_number = max(1, min(page_number, document.total_pages || 1))
    page = Documents.get_page_by_number(document.id, page_number)

    socket
    |> assign(:current_page_number, page_number)
    |> assign(:current_page, page)
  end
end
