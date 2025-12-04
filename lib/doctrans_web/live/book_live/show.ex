defmodule DoctransWeb.DocumentLive.Show do
  @moduledoc """
  Document Viewer LiveView with split-screen layout.

  Shows the original page image on the left and the translated
  markdown on the right. Supports progressive loading while
  processing continues in the background.
  """
  use DoctransWeb, :live_view

  alias Doctrans.Documents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    document = Documents.get_document_with_pages!(id)

    if connected?(socket) do
      Documents.subscribe_document(document.id)
    end

    current_page_number = 1
    current_page = Documents.get_page_by_number(document.id, current_page_number)

    socket =
      socket
      |> assign(:document, document)
      |> assign(:current_page_number, current_page_number)
      |> assign(:current_page, current_page)
      |> assign(:show_original, false)
      |> assign(:zoom_level, 100)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-screen flex flex-col bg-base-100">
        <%!-- Header --%>
        <header class="flex items-center justify-between px-4 py-3 border-b border-base-300 bg-base-200">
          <div class="flex items-center gap-4">
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="w-5 h-5" /> Back
            </.link>
            <div>
              <h1 class="font-semibold text-lg">{@document.title}</h1>
              <div class="flex items-center gap-2 text-sm text-base-content/70">
                <span class={"badge badge-sm #{status_color(@document.status)}"}>
                  {status_text(@document.status)}
                </span>
                <span :if={@document.total_pages}>
                  {language_name(@document.source_language)} to {language_name(
                    @document.target_language
                  )}
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
              <span class="text-sm font-medium">Original Page</span>
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
                {if @show_original, do: "Original Markdown", else: "Translated Content"}
              </span>
              <label class="flex items-center gap-2 cursor-pointer">
                <span class="text-xs text-base-content/70">Show Original</span>
                <input
                  type="checkbox"
                  class="toggle toggle-sm"
                  checked={@show_original}
                  phx-click="toggle_original"
                />
              </label>
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
            <.icon name="hero-chevron-left" class="w-5 h-5" /> Previous
          </button>

          <span class="text-sm text-base-content/70">
            Page {@current_page_number} of {@document.total_pages || "?"}
          </span>

          <button
            type="button"
            phx-click="next_page"
            class="btn btn-ghost"
            disabled={@current_page_number >= (@document.total_pages || 0)}
          >
            Next <.icon name="hero-chevron-right" class="w-5 h-5" />
          </button>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp page_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <select
        id="page-selector"
        phx-change="goto_page"
        name="page"
        class="select select-bordered select-sm w-24"
      >
        <option
          :for={page_num <- 1..max(@total_pages, 1)}
          value={page_num}
          selected={page_num == @current_page}
        >
          {page_num}
        </option>
      </select>
      <span class="text-sm text-base-content/70">/ {@total_pages}</span>
    </div>
    """
  end

  defp page_image(assigns) do
    ~H"""
    <div :if={@page && @page.image_path} class="transition-transform">
      <img
        src={"/uploads/#{@page.image_path}"}
        alt="Page image"
        class="shadow-lg rounded"
        style={"transform: scale(#{@zoom_level / 100}); transform-origin: top center;"}
      />
    </div>
    <div
      :if={!@page || !@page.image_path}
      class="flex flex-col items-center justify-center h-64 text-base-content/50"
    >
      <.icon name="hero-photo" class="w-16 h-16" />
      <p class="mt-4">Page image not available</p>
    </div>
    """
  end

  defp page_content(assigns) do
    ~H"""
    <%!-- Processing state --%>
    <div
      :if={@page && @page.extraction_status == "processing"}
      class="flex flex-col items-center justify-center h-64"
    >
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="mt-4 text-base-content/70">Extracting text from page...</p>
    </div>

    <div
      :if={
        @page && @page.extraction_status == "completed" && @page.translation_status == "processing"
      }
      class="flex flex-col items-center justify-center h-64"
    >
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="mt-4 text-base-content/70">Translating content...</p>
    </div>

    <%!-- Pending state --%>
    <div
      :if={@page && @page.extraction_status == "pending"}
      class="flex flex-col items-center justify-center h-64 text-base-content/50"
    >
      <.icon name="hero-clock" class="w-16 h-16" />
      <p class="mt-4">Waiting to process...</p>
    </div>

    <%!-- Error state --%>
    <div
      :if={@page && (@page.extraction_status == "error" || @page.translation_status == "error")}
      class="flex flex-col items-center justify-center h-64 text-error"
    >
      <.icon name="hero-exclamation-triangle" class="w-16 h-16" />
      <p class="mt-4">An error occurred processing this page</p>
    </div>

    <%!-- Content --%>
    <div :if={@page && show_content?(@page, @show_original)} class="prose prose-sm max-w-none">
      <.markdown_content content={get_content(@page, @show_original)} />
    </div>

    <%!-- No page --%>
    <div :if={!@page} class="flex flex-col items-center justify-center h-64 text-base-content/50">
      <.icon name="hero-document-text" class="w-16 h-16" />
      <p class="mt-4">No page selected</p>
    </div>
    """
  end

  defp markdown_content(assigns) do
    # Simple markdown rendering - convert basic markdown to HTML
    html = render_markdown(assigns.content || "")
    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="whitespace-pre-wrap">{raw(@html)}</div>
    """
  end

  defp render_markdown(nil), do: ""
  defp render_markdown(""), do: ""

  defp render_markdown(text) do
    text
    |> String.trim()
    |> escape_html()
    |> convert_headers()
    |> convert_bold()
    |> convert_italic()
    |> convert_code()
    |> convert_lists()
    |> convert_blockquotes()
    |> convert_paragraphs()
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp convert_headers(text) do
    text
    |> String.replace(~r/^### (.+)$/m, "<h3 class=\"text-lg font-semibold mt-4 mb-2\">\\1</h3>")
    |> String.replace(~r/^## (.+)$/m, "<h2 class=\"text-xl font-semibold mt-6 mb-3\">\\1</h2>")
    |> String.replace(~r/^# (.+)$/m, "<h1 class=\"text-2xl font-bold mt-8 mb-4\">\\1</h1>")
  end

  defp convert_bold(text) do
    String.replace(text, ~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
  end

  defp convert_italic(text) do
    String.replace(text, ~r/\*(.+?)\*/, "<em>\\1</em>")
  end

  defp convert_code(text) do
    text
    |> String.replace(
      ~r/```(\w*)\n([\s\S]*?)```/m,
      "<pre class=\"bg-base-300 p-3 rounded my-2 overflow-x-auto\"><code>\\2</code></pre>"
    )
    |> String.replace(~r/`(.+?)`/, "<code class=\"bg-base-300 px-1 rounded\">\\1</code>")
  end

  defp convert_lists(text) do
    text
    |> String.replace(~r/^- (.+)$/m, "<li class=\"ml-4\">\\1</li>")
    |> String.replace(~r/^\* (.+)$/m, "<li class=\"ml-4\">\\1</li>")
    |> String.replace(~r/^\d+\. (.+)$/m, "<li class=\"ml-4\">\\1</li>")
  end

  defp convert_blockquotes(text) do
    String.replace(
      text,
      ~r/^&gt; (.+)$/m,
      "<blockquote class=\"border-l-4 border-primary pl-4 my-2 italic\">\\1</blockquote>"
    )
  end

  defp convert_paragraphs(text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.map(fn para ->
      para = String.trim(para)

      cond do
        String.starts_with?(para, "<h") -> para
        String.starts_with?(para, "<pre") -> para
        String.starts_with?(para, "<blockquote") -> para
        String.starts_with?(para, "<li") -> "<ul class=\"list-disc my-2\">#{para}</ul>"
        para == "" -> ""
        true -> "<p class=\"my-2\">#{String.replace(para, "\n", "<br>")}</p>"
      end
    end)
    |> Enum.join("\n")
  end

  defp show_content?(page, show_original) do
    if show_original do
      page.extraction_status == "completed" && page.original_markdown
    else
      page.translation_status == "completed" && page.translated_markdown
    end
  end

  defp get_content(page, true), do: page.original_markdown
  defp get_content(page, false), do: page.translated_markdown

  defp status_color("uploading"), do: "badge-info"
  defp status_color("extracting"), do: "badge-warning"
  defp status_color("processing"), do: "badge-warning"
  defp status_color("completed"), do: "badge-success"
  defp status_color("error"), do: "badge-error"
  defp status_color(_), do: "badge-ghost"

  defp status_text("uploading"), do: "Uploading"
  defp status_text("extracting"), do: "Extracting"
  defp status_text("processing"), do: "Processing"
  defp status_text("completed"), do: "Completed"
  defp status_text("error"), do: "Error"
  defp status_text(_), do: "Unknown"

  defp language_name("de"), do: "German"
  defp language_name("en"), do: "English"
  defp language_name("fr"), do: "French"
  defp language_name("es"), do: "Spanish"
  defp language_name("it"), do: "Italian"
  defp language_name("pt"), do: "Portuguese"
  defp language_name("nl"), do: "Dutch"
  defp language_name("pl"), do: "Polish"
  defp language_name("ru"), do: "Russian"
  defp language_name("zh"), do: "Chinese"
  defp language_name("ja"), do: "Japanese"
  defp language_name("ko"), do: "Korean"
  defp language_name(code), do: code

  # Event Handlers

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

  defp goto_page(socket, page_number) do
    document = socket.assigns.document
    page = Documents.get_page_by_number(document.id, page_number)

    socket
    |> assign(:current_page_number, page_number)
    |> assign(:current_page, page)
  end

  # PubSub Handlers

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
