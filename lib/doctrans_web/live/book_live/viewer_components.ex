defmodule DoctransWeb.DocumentLive.ViewerComponents do
  @moduledoc "Components for the document viewer page."
  use DoctransWeb, :html

  attr :current_page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :document, :map, required: true

  def page_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <form phx-change="goto_page" id="page-selector-form">
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

  attr :page, :map, default: nil
  attr :show_original, :boolean, required: true

  def page_content(assigns) do
    ~H"""
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
    <div
      :if={@page && @page.extraction_status == "pending"}
      class="flex flex-col items-center justify-center h-64 text-base-content/50"
    >
      <.icon name="hero-clock" class="w-16 h-16" />
      <p class="mt-4">Waiting to process...</p>
    </div>
    <div
      :if={@page && (@page.extraction_status == "error" || @page.translation_status == "error")}
      class="flex flex-col items-center justify-center h-64 text-error"
    >
      <.icon name="hero-exclamation-triangle" class="w-16 h-16" />
      <p class="mt-4">An error occurred processing this page</p>
    </div>
    <div :if={@page && show_content?(@page, @show_original)} class="prose prose-sm max-w-none">
      <.markdown_content content={get_content(@page, @show_original)} />
    </div>
    <div :if={!@page} class="flex flex-col items-center justify-center h-64 text-base-content/50">
      <.icon name="hero-document-text" class="w-16 h-16" />
      <p class="mt-4">No page selected</p>
    </div>
    """
  end

  attr :content, :string, default: nil

  def markdown_content(assigns) do
    html = render_markdown(assigns.content || "")
    assigns = assign(assigns, :html, html)
    ~H"<div>{raw(@html)}</div>"
  end

  defp render_markdown(nil), do: ""
  defp render_markdown(""), do: ""

  defp render_markdown(text) do
    case Earmark.as_html(text) do
      {:ok, html, _} -> html
      {:error, html, _} -> html
    end
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
end
