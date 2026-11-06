defmodule DoctransWeb.DocumentLive.Viewer do
  @moduledoc """
  Socket state for the document on screen.

  Owns the document half of `DoctransWeb.DocumentLive.Show`: the `:document`
  row, its `:processing_status` and the trailing refresh behind it, the current
  page, and the display settings (panel, zoom, tab). `Show` forwards the
  viewer's events here and hands it every broadcast about the document; the
  answers `document_updated/2`, `document_deleted/1` and `page_updated/2` give
  back -- a run replaced, a document gone, a page on screen -- are what
  `ChatSession` reacts to, so `Show` routes and judges nothing.

  Socket state and the events that change it only; the controls that render
  that state are in `DoctransWeb.DocumentLive.ViewerComponents`, the way
  `ChatSession` and `ChatComponents` divide the chat panel.
  """

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Doctrans.Documents
  alias Doctrans.Documents.ProcessingStatus

  @typedoc "What a document broadcast changed for the viewer."
  @type document_change :: :changed | :run_replaced | :vanished

  @typedoc "Where a page broadcast landed relative to the viewer."
  @type page_change :: :on_screen | :off_screen | :foreign

  # Trailing debounce on `{:page_updated, _}`. A run reports every page as it
  # settles, and the status behind the panel is three queries, so a burst is
  # folded into one refresh once it has gone quiet for this long. Short where
  # `DocumentStream` coalesces for 1.5 s: this is one document, not a grid.
  @status_refresh_ms 100

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

  @doc "Takes `document` on screen: its row, its status, its first page and the display settings."
  def init(socket, document) do
    socket
    |> assign(:document, document)
    |> assign(:status_refresh_pending, false)
    |> refresh_status()
    |> goto_page(1)
    |> assign(:show_original, false)
    |> assign(:zoom_level, default_zoom())
    |> assign(:view_tab, :translated)
  end

  @doc """
  Applies a `{:document_updated, document}` broadcast: the row the broadcast
  carries replaces the one on screen, the current page is resolved against it
  and the status re-read. Answers `:run_replaced` when the document now holds
  a different run, which is the one change the chat has to stop for.
  """
  @spec document_updated(Phoenix.LiveView.Socket.t(), Documents.Document.t()) ::
          {document_change(), Phoenix.LiveView.Socket.t()}
  def document_updated(socket, document) do
    change =
      if document.processing_run_id == socket.assigns.document.processing_run_id,
        do: :changed,
        else: :run_replaced

    socket =
      socket
      |> assign(:document, document)
      |> goto_page(socket.assigns.current_page_number)
      |> refresh_status()

    {change, socket}
  end

  @doc """
  Applies a `{:document_deleted, _}` broadcast: the document is gone, so the
  assign says so and the template's not-found branch renders.
  """
  @spec document_deleted(Phoenix.LiveView.Socket.t()) ::
          {:vanished, Phoenix.LiveView.Socket.t()}
  def document_deleted(socket), do: {:vanished, assign(socket, :document, nil)}

  @doc """
  Applies a `{:page_updated, page}` broadcast. A page of another document, or
  one arriving after the document has gone, is `:foreign` and changes nothing.
  The page on screen is re-read so its content refreshes; any page of the
  document arms the trailing status refresh, once per burst.
  """
  @spec page_updated(Phoenix.LiveView.Socket.t(), Documents.Page.t()) ::
          {page_change(), Phoenix.LiveView.Socket.t()}
  def page_updated(%{assigns: %{document: %{id: id}}} = socket, %{document_id: id} = page) do
    change =
      if socket.assigns.current_page_number == page.page_number, do: :on_screen, else: :off_screen

    socket =
      if change == :on_screen,
        do: assign(socket, :current_page, Documents.get_page_by_number(id, page.page_number)),
        else: socket

    {change, arm_status_refresh(socket)}
  end

  def page_updated(socket, _page), do: {:foreign, socket}

  defp arm_status_refresh(%{assigns: %{status_refresh_pending: true}} = socket), do: socket

  defp arm_status_refresh(socket) do
    Process.send_after(self(), :refresh_status, @status_refresh_ms)
    assign(socket, :status_refresh_pending, true)
  end

  @doc "The trailing refresh landing: re-reads the status once the burst has gone quiet."
  def refresh_pending(socket) do
    socket |> assign(:status_refresh_pending, false) |> refresh_status()
  end

  @doc """
  Re-reads the document's processing status. Called on mount, on every
  document broadcast, after a page burst and after a status-panel action, so
  the panel follows the pipelines live without a subscription of its own.
  """
  def refresh_status(%{assigns: %{document: nil}} = socket), do: socket

  def refresh_status(socket) do
    assign(socket, :processing_status, ProcessingStatus.for_document(socket.assigns.document))
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
