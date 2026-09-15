defmodule DoctransWeb.DocumentLive.ViewerComponents do
  @moduledoc "Components for the document viewer page."
  use DoctransWeb, :html

  import DoctransWeb.DocumentLive.MarkdownHelpers, only: [render_markdown: 1]

  attr :current_page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :document, :map, required: true

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

  @doc """
  Shows which models produced the current page's content.

  The identifiers are whatever the processing run recorded: an alias such as
  `gpt-4o` names an endpoint, not a fixed set of weights, so the line says the
  models were *reported*, and never claims the page can be reproduced from them.
  Pages processed before provenance was recorded keep a null column, which is
  reported as unknown rather than backfilled with today's configuration.
  """
  def page_provenance(assigns) do
    ~H"""
    <div
      :if={@page}
      id="page-processing-models"
      class="border-b border-base-300 px-4 py-2 text-xs text-base-content/60"
    >
      <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span id="page-extraction-model">
          {gettext("Extraction: %{model}",
            model: model_label(@page.extraction_model, @page.extraction_status)
          )}
        </span>
        <span id="page-translation-model">
          {gettext("Translation: %{model}",
            model: model_label(@page.translation_model, @page.translation_status)
          )}
        </span>
      </p>
      <p id="page-processing-models-caveat" class="mt-1 text-base-content/50">
        {gettext(
          "Model names are the aliases reported during processing and may not identify the exact weights used."
        )}
      </p>
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
      <p class="mt-4 text-base-content/70">{gettext("Extracting text from page...")}</p>
    </div>
    <div
      :if={
        @page && !@show_original && @page.extraction_status == "completed" &&
          @page.translation_status == "processing"
      }
      class="flex flex-col items-center justify-center h-64"
    >
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="mt-4 text-base-content/70">{gettext("Translating content...")}</p>
    </div>
    <div
      :if={@page && @page.extraction_status == "pending"}
      class="flex flex-col items-center justify-center h-64 text-base-content/50"
    >
      <.icon name="hero-clock" class="w-16 h-16" />
      <p class="mt-4">{gettext("Waiting to process...")}</p>
    </div>
    <div
      :if={@page && (@page.extraction_status == "error" || @page.translation_status == "error")}
      class="flex flex-col items-center justify-center h-64 text-error"
    >
      <.icon name="hero-exclamation-triangle" class="w-16 h-16" />
      <p class="mt-4">{gettext("An error occurred processing this page")}</p>
    </div>
    <div :if={@page && show_content?(@page, @show_original)} class="markdown markdown-sm">
      <.markdown_content content={get_content(@page, @show_original)} />
    </div>
    <div :if={!@page} class="flex flex-col items-center justify-center h-64 text-base-content/50">
      <.icon name="hero-document-text" class="w-16 h-16" />
      <p class="mt-4">{gettext("No page selected")}</p>
    </div>
    """
  end

  attr :content, :string, default: nil

  def markdown_content(assigns) do
    html = render_markdown(assigns.content || "")
    assigns = assign(assigns, :html, html)
    # No wrapper element: the rendered blocks must be direct children of the
    # `.markdown` container so its edge-margin rules (`.markdown > :first-child`) match.
    ~H"{raw(@html)}"
  end

  # A stage that has not finished has nothing recorded yet, which is a different
  # statement from a stage that finished without recording anything.
  defp model_label(nil, status) when status in ~w(pending processing),
    do: gettext("not recorded yet")

  defp model_label(nil, _status), do: gettext("Unknown")
  defp model_label(model, _status), do: model

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
