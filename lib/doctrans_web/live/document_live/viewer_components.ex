defmodule DoctransWeb.DocumentLive.ViewerComponents do
  @moduledoc "Components for the document viewer page."
  use DoctransWeb, :html

  import DoctransWeb.DocumentLive.MarkdownHelpers, only: [render_markdown: 1]

  alias Doctrans.Documents.Page

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

  @doc """
  Shows which models produced the current page's content.

  The identifiers are whatever the processing run recorded: an alias such as
  `gpt-4o` names an endpoint, not a fixed set of weights, so the caveat says the
  models were *reported*, and never claims the page can be reproduced from them.
  A null column is never backfilled from today's configuration, which would
  attribute the current setting to a past run.

  Each state is its own complete message rather than a fragment interpolated
  after "Extraction:", so every language controls agreement and word order.
  """
  attr :page, :map, default: nil

  def page_provenance(assigns) do
    ~H"""
    <section
      :if={@page}
      id="page-processing-models"
      class="border-b border-base-300 px-4 py-2 text-xs text-base-content/60"
      aria-label={gettext("Page processing models")}
    >
      <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span id="page-extraction-model">{extraction_label(@page)}</span>
        <span id="page-translation-model">{translation_label(@page)}</span>
      </p>
      <%!-- An alias caveat has nothing to qualify unless a name is on screen. --%>
      <p
        :if={named_model?(@page)}
        id="page-processing-models-caveat"
        class="mt-1 text-base-content/50"
      >
        {gettext(
          "Model names are the aliases reported during processing and may not identify the exact weights used."
        )}
      </p>
    </section>
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

  defp extraction_label(page) do
    case extraction_state(page) do
      {:recorded, model} -> gettext("Extraction: %{model}", model: model)
      :in_flight -> gettext("Extraction: not recorded yet")
      :failed -> gettext("Extraction: run failed")
      :unrecorded -> gettext("Extraction: unknown")
    end
  end

  defp translation_label(page) do
    case translation_state(page) do
      {:recorded, model} -> gettext("Translation: %{model}", model: model)
      :in_flight -> gettext("Translation: not recorded yet")
      :failed -> gettext("Translation: run failed")
      :never_ran -> gettext("Translation: did not run")
      :not_needed -> gettext("Translation: no content to translate")
      :unrecorded -> gettext("Translation: unknown")
    end
  end

  # Extraction always calls a model when it runs, so a null column is work still
  # in flight, a run that failed, or a page that predates provenance recording.
  defp extraction_state(%{extraction_model: model}) when is_binary(model), do: {:recorded, model}

  defp extraction_state(%{extraction_status: status}) when status in ~w(pending processing),
    do: :in_flight

  defp extraction_state(%{extraction_status: "error"}), do: :failed
  defp extraction_state(_page), do: :unrecorded

  defp translation_state(%{translation_model: model}) when is_binary(model),
    do: {:recorded, model}

  defp translation_state(%{translation_status: "error"}), do: :failed

  # Translation starts only once extraction has completed, so on a page whose
  # extraction errored a pending status is terminal, not work still queued.
  defp translation_state(%{translation_status: status} = page)
       when status in ~w(pending processing) do
    if Page.failed_status?(page), do: :never_ran, else: :in_flight
  end

  # `LlmProcessor` completes a page with no extracted text without calling a
  # model at all, so that null column is an accurate record, not a gap.
  defp translation_state(%{translation_status: "completed", original_markdown: markdown})
       when markdown in [nil, ""],
       do: :not_needed

  defp translation_state(_page), do: :unrecorded

  defp named_model?(page) do
    match?({:recorded, _}, extraction_state(page)) or
      match?({:recorded, _}, translation_state(page))
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
