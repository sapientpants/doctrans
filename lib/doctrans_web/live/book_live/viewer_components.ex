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
      <p class="mt-4">{gettext("Page image not available")}</p>
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
    <div :if={@page && show_content?(@page, @show_original)} class="prose prose-sm max-w-none">
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
    ~H"<div>{raw(@html)}</div>"
  end

  attr :page, :map, required: true
  attr :extraction_model, :string, required: true
  attr :translation_model, :string, required: true
  attr :available_models, :list, required: true
  attr :models_loading, :boolean, default: false
  attr :model_fetch_error, :string, default: nil

  def reprocess_modal(assigns) do
    assigns = assign(assigns, :sorted_models, Enum.sort(assigns.available_models))

    ~H"""
    <div class="modal modal-open" id="reprocess-modal">
      <div class="modal-box max-w-md">
        <button
          type="button"
          phx-click="hide_reprocess_modal"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>

        <h3 class="font-bold text-lg mb-4">{gettext("Reprocess Page")}</h3>
        <p class="text-sm text-base-content/70 mb-4">
          {gettext("Select models to use for re-extracting and re-translating this page.")}
        </p>

        <div :if={@model_fetch_error} class="alert alert-error mb-4">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{@model_fetch_error}</span>
        </div>

        <form phx-submit="reprocess_page" phx-change="update_reprocess_models" id="reprocess-form">
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text">{gettext("Extraction Model")}</span>
            </label>
            <select
              name="extraction_model"
              class="select select-bordered w-full"
              id="extraction-model-select"
              disabled={@models_loading}
            >
              <option :if={@models_loading} value="">{gettext("Loading models...")}</option>
              <option
                :for={model <- @sorted_models}
                :if={!@models_loading}
                value={model}
                selected={model == @extraction_model}
              >
                {model}
              </option>
            </select>
          </div>

          <div class="form-control mb-6">
            <label class="label">
              <span class="label-text">{gettext("Translation Model")}</span>
            </label>
            <select
              name="translation_model"
              class="select select-bordered w-full"
              id="translation-model-select"
              disabled={@models_loading}
            >
              <option :if={@models_loading} value="">{gettext("Loading models...")}</option>
              <option
                :for={model <- @sorted_models}
                :if={!@models_loading}
                value={model}
                selected={model == @translation_model}
              >
                {model}
              </option>
            </select>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="hide_reprocess_modal" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@models_loading || @available_models == []}
              id="reprocess-submit-btn"
            >
              {gettext("Reprocess")}
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="hide_reprocess_modal"></div>
    </div>
    """
  end

  defp render_markdown(nil), do: ""
  defp render_markdown(""), do: ""

  defp render_markdown(text) do
    case Earmark.as_html(text) do
      {:ok, html, _} -> sanitize_html(html)
      {:error, html, _} -> sanitize_html(html)
    end
  end

  # Sanitize HTML to prevent XSS attacks from user-uploaded content
  defp sanitize_html(html) do
    HtmlSanitizeEx.basic_html(html)
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
