defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc "Document Viewer LiveView with split-screen layout."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Processing.{Ollama, Worker}

  import DoctransWeb.DocumentLive.Components,
    only: [status_color: 1, status_text: 1, language_name: 1]

  import DoctransWeb.DocumentLive.ViewerComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    document = Documents.get_document_with_pages!(id)

    if connected?(socket) do
      Documents.subscribe_document(document.id)
    end

    current_page_number = 1
    current_page = Documents.get_page_by_number(document.id, current_page_number)

    # Get default models from config
    ollama_config = Application.get_env(:doctrans, :ollama, [])

    socket =
      socket
      |> assign(:document, document)
      |> assign(:current_page_number, current_page_number)
      |> assign(:current_page, current_page)
      |> assign(:show_original, false)
      |> assign(:zoom_level, 100)
      |> assign(:from, nil)
      |> assign(:search_query, nil)
      # Reprocess modal state
      |> assign(:show_reprocess_modal, false)
      |> assign(:available_models, [])
      |> assign(:models_loading, false)
      |> assign(:extraction_model, ollama_config[:vision_model] || "ministral-3:14b")
      |> assign(:translation_model, ollama_config[:text_model] || "ministral-3:14b")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> maybe_assign_from(params)
      |> maybe_goto_page(params)

    {:noreply, socket}
  end

  defp maybe_assign_from(socket, params) do
    from = Map.get(params, "from")
    search_query = Map.get(params, "q")

    socket
    |> assign(:from, from)
    |> assign(:search_query, search_query)
  end

  defp maybe_goto_page(socket, %{"page" => page_str}) do
    case Integer.parse(page_str) do
      {page_number, _} ->
        max_page = socket.assigns.document.total_pages || 1
        page_number = max(1, min(page_number, max_page))
        goto_page(socket, page_number)

      :error ->
        socket
    end
  end

  defp maybe_goto_page(socket, _params), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-screen flex flex-col bg-base-100 max-w-full">
        <%!-- Header --%>
        <header class="flex items-center justify-between px-4 pr-8 py-3 border-b border-base-300 bg-base-200">
          <div class="flex items-center gap-4">
            <.link navigate={back_url(@from, @search_query)} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="w-5 h-5" /> {gettext("Back")}
            </.link>
            <div>
              <h1 class="font-semibold text-lg">{@document.title}</h1>
              <div class="flex items-center gap-2 text-sm text-base-content/70">
                <span class={"badge badge-sm #{status_color(@document.status)}"}>
                  {status_text(@document.status)}
                </span>
                <span :if={@document.total_pages}>
                  {language_name(@document.target_language)}
                </span>
              </div>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <.page_selector
              current_page={@current_page_number}
              total_pages={@document.total_pages || 0}
              document={@document}
            />
          </div>
        </header>

        <%!-- Main content - Split screen --%>
        <main class="flex-1 flex overflow-hidden">
          <%!-- Left panel - Page image --%>
          <div class="w-1/2 border-r border-base-300 flex flex-col bg-base-200">
            <div class="flex items-center justify-between px-4 py-2 border-b border-base-300">
              <span class="text-sm font-medium">{gettext("Original Page")}</span>
              <div class="flex items-center gap-1">
                <button
                  type="button"
                  phx-click="zoom_out"
                  class="btn btn-ghost btn-xs"
                  disabled={@zoom_level <= 50}
                >
                  <.icon name="hero-minus" class="w-4 h-4" />
                </button>
                <span class="text-xs w-12 text-center">{@zoom_level}%</span>
                <button
                  type="button"
                  phx-click="zoom_in"
                  class="btn btn-ghost btn-xs"
                  disabled={@zoom_level >= 200}
                >
                  <.icon name="hero-plus" class="w-4 h-4" />
                </button>
              </div>
            </div>
            <div class="flex-1 overflow-auto p-4 flex items-start justify-center">
              <.page_image page={@current_page} zoom_level={@zoom_level} />
            </div>
          </div>

          <%!-- Right panel - Translated content --%>
          <div class="w-1/2 flex flex-col">
            <div class="flex items-center justify-between px-4 py-2 border-b border-base-300">
              <span class="text-sm font-medium">
                {if @show_original,
                  do: gettext("Original Content"),
                  else: gettext("Translated Content")}
              </span>
              <div class="flex items-center gap-2">
                <button
                  :if={can_reprocess?(@current_page)}
                  type="button"
                  phx-click="show_reprocess_modal"
                  class="btn btn-ghost btn-xs"
                  title={gettext("Reprocess this page")}
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4" />
                </button>
                <label class="flex items-center gap-2 cursor-pointer">
                  <span class="text-xs text-base-content/70">{gettext("Show Original")}</span>
                  <input
                    type="checkbox"
                    class="toggle toggle-sm"
                    checked={@show_original}
                    phx-click="toggle_original"
                  />
                </label>
              </div>
            </div>
            <div class="flex-1 overflow-auto p-6">
              <.page_content page={@current_page} show_original={@show_original} />
            </div>
          </div>
        </main>

        <%!-- Footer - Navigation --%>
        <footer class="flex items-center justify-center gap-4 px-4 py-3 border-t border-base-300 bg-base-200">
          <button
            type="button"
            phx-click="prev_page"
            class="btn btn-ghost"
            disabled={@current_page_number <= 1}
          >
            <.icon name="hero-chevron-left" class="w-5 h-5" /> {gettext("Previous")}
          </button>

          <span class="text-sm text-base-content/70">
            {gettext("Page %{current} of %{total}",
              current: @current_page_number,
              total: @document.total_pages || "?"
            )}
          </span>

          <button
            type="button"
            phx-click="next_page"
            class="btn btn-ghost"
            disabled={@current_page_number >= (@document.total_pages || 0)}
          >
            {gettext("Next")} <.icon name="hero-chevron-right" class="w-5 h-5" />
          </button>
        </footer>
      </div>

      <%!-- Reprocess Modal --%>
      <.reprocess_modal
        :if={@show_reprocess_modal}
        page={@current_page}
        extraction_model={@extraction_model}
        translation_model={@translation_model}
        available_models={@available_models}
        models_loading={@models_loading}
      />
    </Layouts.app>
    """
  end

  defp back_url("search", query) when is_binary(query) and query != "" do
    ~p"/search?q=#{query}"
  end

  defp back_url(_from, _query), do: ~p"/"

  # Show reprocess button when page has completed processing or has an error
  # but not when it's currently processing (to prevent double-processing)
  defp can_reprocess?(nil), do: false

  defp can_reprocess?(page) do
    page.extraction_status in ["completed", "error"] ||
      page.translation_status == "error"
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    new_page_number = max(1, socket.assigns.current_page_number - 1)
    {:noreply, goto_page(socket, new_page_number)}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    max_page = socket.assigns.document.total_pages || 1
    new_page_number = min(max_page, socket.assigns.current_page_number + 1)
    {:noreply, goto_page(socket, new_page_number)}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page_number, _} -> {:noreply, goto_page(socket, page_number)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_original", _params, socket) do
    {:noreply, assign(socket, :show_original, !socket.assigns.show_original)}
  end

  @impl true
  def handle_event("zoom_in", _params, socket) do
    new_zoom = min(200, socket.assigns.zoom_level + 25)
    {:noreply, assign(socket, :zoom_level, new_zoom)}
  end

  @impl true
  def handle_event("zoom_out", _params, socket) do
    new_zoom = max(50, socket.assigns.zoom_level - 25)
    {:noreply, assign(socket, :zoom_level, new_zoom)}
  end

  @impl true
  def handle_event("show_reprocess_modal", _params, socket) do
    # Show modal and trigger async model fetch
    socket =
      socket
      |> assign(:show_reprocess_modal, true)
      |> assign(:models_loading, true)

    send(self(), :fetch_available_models)

    {:noreply, socket}
  end

  @impl true
  def handle_event("hide_reprocess_modal", _params, socket) do
    {:noreply, assign(socket, :show_reprocess_modal, false)}
  end

  @impl true
  def handle_event("update_reprocess_models", params, socket) do
    socket =
      socket
      |> assign(:extraction_model, params["extraction_model"] || socket.assigns.extraction_model)
      |> assign(
        :translation_model,
        params["translation_model"] || socket.assigns.translation_model
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("reprocess_page", params, socket) do
    page = socket.assigns.current_page
    extraction_model = params["extraction_model"]
    translation_model = params["translation_model"]

    # Reset the page for reprocessing
    {:ok, page} = Documents.reset_page_for_reprocessing(page)
    Documents.broadcast_page_update(page)

    # Queue for reprocessing with custom models
    Worker.queue_page_reprocess(page.id,
      extraction_model: extraction_model,
      translation_model: translation_model
    )

    socket =
      socket
      |> assign(:current_page, page)
      |> assign(:show_reprocess_modal, false)
      |> put_flash(:info, gettext("Page queued for reprocessing"))

    {:noreply, socket}
  end

  defp goto_page(socket, page_number) do
    document = socket.assigns.document
    page = Documents.get_page_by_number(document.id, page_number)

    socket
    |> assign(:current_page_number, page_number)
    |> assign(:current_page, page)
  end

  # PubSub Handlers

  @impl true
  def handle_info(:fetch_available_models, socket) do
    models =
      case Ollama.list_models() do
        {:ok, models} -> models
        {:error, _} -> []
      end

    socket =
      socket
      |> assign(:available_models, models)
      |> assign(:models_loading, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:document_updated, document}, socket) do
    {:noreply, assign(socket, :document, document)}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    # Update the current page if it's the one that was updated
    socket =
      if socket.assigns.current_page && socket.assigns.current_page.id == page.id do
        assign(socket, :current_page, page)
      else
        socket
      end

    # Also refresh the document to update progress
    document = Documents.get_document_with_pages!(socket.assigns.document.id)
    {:noreply, assign(socket, :document, document)}
  end
end
