defmodule DoctransWeb.DocumentLive.Components do
  @moduledoc """
  Shared UI components for document LiveViews.
  """
  use DoctransWeb, :html

  @doc """
  Renders a document card for the dashboard grid.
  """
  attr :document, :map, required: true

  def document_card(assigns) do
    progress = Map.get(assigns.document, :progress, 0.0)

    assigns =
      assigns
      |> assign(:progress, progress)
      |> assign(:status_color, status_color(assigns.document.status))
      |> assign(:status_text, status_text(assigns.document.status))

    ~H"""
    <div class="card bg-base-200 shadow-lg hover:shadow-xl transition-shadow">
      <.link navigate={~p"/documents/#{@document.id}"} class="block">
        <figure class="px-4 pt-4">
          <div class="aspect-[3/4] bg-base-300 rounded-lg flex items-center justify-center overflow-hidden">
            <.document_thumbnail document={@document} />
          </div>
        </figure>
      </.link>
      <div class="card-body p-4">
        <h2 class="card-title text-base truncate" title={@document.title}>
          {@document.title}
        </h2>
        <div class="flex items-center gap-2 mt-2">
          <span class={"badge badge-sm #{@status_color}"}>
            {@status_text}
          </span>
          <span :if={@document.total_pages} class="text-xs text-base-content/70">
            {@document.total_pages} pages
          </span>
        </div>
        <div :if={@document.status in ["extracting", "processing"]} class="mt-2">
          <div class="flex justify-between text-xs mb-1">
            <span>Progress</span>
            <span>{Float.round(@progress, 1)}%</span>
          </div>
          <progress class="progress progress-primary w-full" value={@progress} max="100" />
        </div>
        <div class="card-actions justify-end mt-2">
          <button
            type="button"
            phx-click="delete_document"
            phx-value-id={@document.id}
            data-confirm="Are you sure you want to delete this document? This cannot be undone."
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a document thumbnail from its first page.
  """
  attr :document, :map, required: true

  def document_thumbnail(assigns) do
    document = assigns.document
    pages = Map.get(document, :pages, [])
    first_page = Enum.find(pages, &(&1.page_number == 1))

    assigns = assign(assigns, :first_page, first_page)

    ~H"""
    <img
      :if={@first_page && @first_page.image_path}
      src={"/uploads/#{@first_page.image_path}"}
      alt="First page"
      class="w-full h-full object-cover"
    />
    <.icon
      :if={!@first_page || !@first_page.image_path}
      name="hero-document-text"
      class="w-16 h-16 text-base-content/30"
    />
    """
  end

  @doc """
  Renders the upload modal dialog.
  """
  attr :uploads, :map, required: true
  attr :target_language, :string, required: true

  def upload_modal(assigns) do
    ~H"""
    <div class="modal modal-open" id="upload-modal">
      <div class="modal-box max-w-lg">
        <button
          type="button"
          phx-click="hide_upload_modal"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>

        <h3 class="font-bold text-lg mb-4">Upload New Document</h3>

        <form phx-submit="upload_document" phx-change="validate_upload" id="upload-form">
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text">PDF Files</span>
            </label>
            <div
              class="border-2 border-dashed border-base-300 rounded-lg p-4 text-center hover:border-primary transition-colors"
              phx-drop-target={@uploads.pdf.ref}
            >
              <.live_file_input upload={@uploads.pdf} class="hidden" />
              <.upload_empty_state :if={@uploads.pdf.entries == []} upload={@uploads.pdf} />
              <.upload_entries_list :if={@uploads.pdf.entries != []} upload={@uploads.pdf} />
              <.upload_error :for={err <- upload_errors(@uploads.pdf)} error={err} />
            </div>
          </div>

          <div class="form-control mb-6">
            <label class="label">
              <span class="label-text">Target Language</span>
            </label>
            <select
              name="target_language"
              class="select select-bordered w-full"
              id="target-lang-select"
            >
              <.language_options selected={@target_language} />
            </select>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="hide_upload_modal" class="btn btn-ghost">
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@uploads.pdf.entries == []}
              id="start-translation-btn"
            >
              Start Translation
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="hide_upload_modal"></div>
    </div>
    """
  end

  defp upload_empty_state(assigns) do
    ~H"""
    <div class="py-4">
      <.icon name="hero-cloud-arrow-up" class="w-12 h-12 mx-auto text-base-content/50" />
      <p class="mt-2 text-sm text-base-content/70">
        Drag and drop PDF files here, or
        <label for={@upload.ref} class="link link-primary cursor-pointer">
          browse
        </label>
      </p>
      <p class="mt-1 text-xs text-base-content/50">Up to 10 files at once</p>
    </div>
    """
  end

  defp upload_entries_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <div :for={entry <- @upload.entries} class="flex items-center gap-2 bg-base-200 rounded-lg p-2">
        <.icon name="hero-document" class="w-6 h-6 text-primary shrink-0" />
        <div class="flex-1 text-left min-w-0">
          <p class="text-sm font-medium truncate">{entry.client_name}</p>
          <progress class="progress progress-primary w-full h-1" value={entry.progress} max="100" />
        </div>
        <button
          type="button"
          phx-click="cancel_upload"
          phx-value-ref={entry.ref}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      <label
        for={@upload.ref}
        class="block text-xs text-base-content/50 cursor-pointer hover:text-primary mt-2"
      >
        + Add more files
      </label>
    </div>
    """
  end

  @doc """
  Renders language options for the select dropdown.
  """
  attr :selected, :string, required: true

  def language_options(assigns) do
    languages = [
      {"de", "German"},
      {"en", "English"},
      {"fr", "French"},
      {"es", "Spanish"},
      {"it", "Italian"},
      {"pt", "Portuguese"},
      {"nl", "Dutch"},
      {"pl", "Polish"},
      {"ru", "Russian"},
      {"zh", "Chinese"},
      {"ja", "Japanese"},
      {"ko", "Korean"}
    ]

    assigns = assign(assigns, :languages, languages)

    ~H"""
    <option :for={{code, name} <- @languages} value={code} selected={code == @selected}>
      {name}
    </option>
    """
  end

  defp upload_error(assigns) do
    ~H"""
    <p class="text-error text-sm mt-2">
      {error_to_string(@error)}
    </p>
    """
  end

  defp error_to_string(:too_large), do: "File is too large (max 100MB)"
  defp error_to_string(:too_many_files), do: "Maximum 10 files can be uploaded at once"
  defp error_to_string(:not_accepted), do: "Only PDF files are accepted"
  defp error_to_string(err), do: "Error: #{inspect(err)}"

  @doc """
  Returns the badge color class for a document status.
  """
  def status_color("uploading"), do: "badge-info"
  def status_color("extracting"), do: "badge-info"
  def status_color("queued"), do: "badge-info"
  def status_color("processing"), do: "badge-warning"
  def status_color("completed"), do: "badge-success"
  def status_color("error"), do: "badge-error"
  def status_color(_), do: "badge-ghost"

  @doc """
  Returns the display text for a document status.
  """
  def status_text("uploading"), do: "Uploading"
  def status_text("extracting"), do: "Processing"
  def status_text("queued"), do: "Queued"
  def status_text("processing"), do: "Processing"
  def status_text("completed"), do: "Completed"
  def status_text("error"), do: "Error"
  def status_text(_), do: "Unknown"

  @doc """
  Returns the sort label for the sort dropdown.
  """
  def sort_label(:inserted_at, :desc), do: "Newest"
  def sort_label(:inserted_at, :asc), do: "Oldest"
  def sort_label(:title, :asc), do: "A-Z"
  def sort_label(:title, :desc), do: "Z-A"
  def sort_label(_, _), do: "Sort"

  @doc """
  Returns the display name for a language code.
  """
  def language_name("de"), do: "German"
  def language_name("en"), do: "English"
  def language_name("fr"), do: "French"
  def language_name("es"), do: "Spanish"
  def language_name("it"), do: "Italian"
  def language_name("pt"), do: "Portuguese"
  def language_name("nl"), do: "Dutch"
  def language_name("pl"), do: "Polish"
  def language_name("ru"), do: "Russian"
  def language_name("zh"), do: "Chinese"
  def language_name("ja"), do: "Japanese"
  def language_name("ko"), do: "Korean"
  def language_name(code), do: code
end
