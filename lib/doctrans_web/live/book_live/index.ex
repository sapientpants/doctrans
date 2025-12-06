defmodule DoctransWeb.DocumentLive.Index do
  @moduledoc """
  Dashboard LiveView for managing documents.

  Shows all documents with their processing status and allows
  uploading new PDFs for translation.
  """
  use DoctransWeb, :live_view
  require Logger

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker

  @impl true
  def mount(_params, _session, socket) do
    documents = Documents.list_documents() |> add_progress_to_documents()
    defaults = Application.get_env(:doctrans, :defaults, [])

    if connected?(socket) do
      # Subscribe to the general documents topic
      Logger.info("Dashboard subscribing to documents topic")
      Phoenix.PubSub.subscribe(Doctrans.PubSub, "documents")

      # Also subscribe to each individual document's topic for progress updates
      for doc <- documents do
        Logger.info("Dashboard subscribing to document:#{doc.id}")
        Phoenix.PubSub.subscribe(Doctrans.PubSub, "document:#{doc.id}")
      end
    end

    socket =
      socket
      |> assign(:documents, documents)
      |> assign(:show_upload_modal, false)
      |> assign(:target_language, defaults[:target_language] || "en")
      |> allow_upload(:pdf,
        accept: ~w(.pdf),
        max_entries: 10,
        max_file_size: Application.get_env(:doctrans, :uploads)[:max_file_size] || 100_000_000
      )

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
      <div class="w-full px-6 py-8">
        <div class="flex justify-between items-center mb-8">
          <div>
            <h1 class="text-3xl font-bold text-base-content">Doctrans</h1>
            <p class="text-base-content/70 mt-1">PDF Document Translator</p>
          </div>
          <button
            type="button"
            phx-click="show_upload_modal"
            class="btn btn-primary"
            id="upload-document-btn"
          >
            <.icon name="hero-plus" class="w-5 h-5 mr-2" /> Upload Document
          </button>
        </div>

        <div :if={@documents == []} class="text-center py-16">
          <.icon name="hero-document-text" class="w-16 h-16 mx-auto text-base-content/30" />
          <h3 class="mt-4 text-lg font-medium text-base-content">No documents yet</h3>
          <p class="mt-2 text-base-content/70">Upload a PDF to get started with translation.</p>
        </div>

        <div
          :if={@documents != []}
          class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6 gap-6"
        >
          <.document_card :for={document <- @documents} document={document} />
        </div>
      </div>

      <.upload_modal
        :if={@show_upload_modal}
        uploads={@uploads}
        target_language={@target_language}
      />
    </Layouts.app>
    """
  end

  defp document_card(assigns) do
    # Use pre-calculated progress from document map (set in mount/handle_info)
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

  defp document_thumbnail(assigns) do
    document = assigns.document
    # Use preloaded pages to avoid extra DB query
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

  defp upload_modal(assigns) do
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
              <div :if={@uploads.pdf.entries == []} class="py-4">
                <.icon name="hero-cloud-arrow-up" class="w-12 h-12 mx-auto text-base-content/50" />
                <p class="mt-2 text-sm text-base-content/70">
                  Drag and drop PDF files here, or
                  <label for={@uploads.pdf.ref} class="link link-primary cursor-pointer">
                    browse
                  </label>
                </p>
                <p class="mt-1 text-xs text-base-content/50">Up to 10 files at once</p>
              </div>
              <div :if={@uploads.pdf.entries != []} class="space-y-2">
                <div
                  :for={entry <- @uploads.pdf.entries}
                  class="flex items-center gap-2 bg-base-200 rounded-lg p-2"
                >
                  <.icon name="hero-document" class="w-6 h-6 text-primary shrink-0" />
                  <div class="flex-1 text-left min-w-0">
                    <p class="text-sm font-medium truncate">{entry.client_name}</p>
                    <progress
                      class="progress progress-primary w-full h-1"
                      value={entry.progress}
                      max="100"
                    />
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
                  for={@uploads.pdf.ref}
                  class="block text-xs text-base-content/50 cursor-pointer hover:text-primary mt-2"
                >
                  + Add more files
                </label>
              </div>
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

  defp language_options(assigns) do
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

  defp status_color("uploading"), do: "badge-info"
  defp status_color("queued"), do: "badge-info"
  defp status_color(status) when status in ["extracting", "processing"], do: "badge-warning"
  defp status_color("completed"), do: "badge-success"
  defp status_color("error"), do: "badge-error"
  defp status_color(_), do: "badge-ghost"

  defp status_text("uploading"), do: "Uploading"
  defp status_text("queued"), do: "Queued"
  defp status_text(status) when status in ["extracting", "processing"], do: "Processing"
  defp status_text("completed"), do: "Completed"
  defp status_text("error"), do: "Error"
  defp status_text(_), do: "Unknown"

  # Event Handlers

  @impl true
  def handle_event("show_upload_modal", _params, socket) do
    {:noreply, assign(socket, :show_upload_modal, true)}
  end

  @impl true
  def handle_event("hide_upload_modal", _params, socket) do
    {:noreply, assign(socket, :show_upload_modal, false)}
  end

  @impl true
  def handle_event("validate_upload", params, socket) do
    target_language = params["target_language"] || socket.assigns.target_language
    {:noreply, assign(socket, :target_language, target_language)}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  @impl true
  def handle_event("upload_document", params, socket) do
    target_language = params["target_language"] || socket.assigns.target_language

    # Consume all uploaded files
    uploaded_files =
      consume_uploaded_entries(socket, :pdf, fn %{path: path}, entry ->
        document_id = Uniq.UUID.uuid7()
        dest_dir = Documents.document_upload_dir(document_id)
        File.mkdir_p!(dest_dir)
        dest_path = Path.join(dest_dir, "original.pdf")
        File.cp!(path, dest_path)
        {:ok, {document_id, entry.client_name, dest_path}}
      end)

    case uploaded_files do
      [] ->
        {:noreply, put_flash(socket, :error, "No files were uploaded")}

      files ->
        # Create a document for each uploaded file
        Enum.each(files, fn {document_id, original_filename, pdf_path} ->
          title =
            original_filename
            |> Path.basename(".pdf")
            |> String.replace(~r/[_-]+/, " ")

          case Documents.create_document(%{
                 id: document_id,
                 title: title,
                 original_filename: original_filename,
                 target_language: target_language,
                 status: "uploading"
               }) do
            {:ok, document} ->
              Logger.info("Subscribing to new document:#{document.id}")
              Phoenix.PubSub.subscribe(Doctrans.PubSub, "document:#{document.id}")
              Worker.process_document(document.id, pdf_path)

            {:error, _changeset} ->
              File.rm(pdf_path)
          end
        end)

        file_count = length(files)

        message =
          if file_count == 1, do: "Document uploaded!", else: "#{file_count} documents uploaded!"

        socket =
          socket
          |> assign(:documents, Documents.list_documents())
          |> assign(:show_upload_modal, false)
          |> put_flash(:info, "#{message} Processing will begin shortly.")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_document", %{"id" => id}, socket) do
    document = Documents.get_document!(id)

    # Cancel any in-progress processing
    Worker.cancel_document(document.id)

    case Documents.delete_document(document) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:documents, Documents.list_documents())
          |> put_flash(:info, "Document deleted successfully")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete document")}
    end
  end

  # Helper to pre-calculate progress for documents
  defp add_progress_to_documents(documents) do
    Enum.map(documents, fn doc ->
      progress = Documents.calculate_progress_preloaded(doc)
      Map.put(doc, :progress, progress)
    end)
  end

  # PubSub Handlers

  @impl true
  def handle_info({:document_updated, document}, socket) do
    Logger.info("Dashboard received document_updated for #{document.id}")
    documents = Documents.list_documents() |> add_progress_to_documents()
    {:noreply, assign(socket, :documents, documents)}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    Logger.info(
      "Dashboard received page_updated for page #{page.page_number} of document #{page.document_id}"
    )

    documents = Documents.list_documents() |> add_progress_to_documents()
    {:noreply, assign(socket, :documents, documents)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.warning("Dashboard received unknown message: #{inspect(msg)}")
    {:noreply, socket}
  end
end
