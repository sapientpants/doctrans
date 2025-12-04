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
    documents = Documents.list_documents()
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
      |> assign(:document_title, "")
      |> allow_upload(:pdf,
        accept: ~w(.pdf),
        max_entries: 1,
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
        source_language={@source_language}
        target_language={@target_language}
        document_title={@document_title}
      />
    </Layouts.app>
    """
  end

  defp document_card(assigns) do
    progress = Documents.calculate_progress(assigns.document)

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
    pages = Documents.list_pages(document.id)
    first_page = List.first(pages)

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
              <span class="label-text">PDF File</span>
            </label>
            <div
              class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center hover:border-primary transition-colors"
              phx-drop-target={@uploads.pdf.ref}
            >
              <.live_file_input upload={@uploads.pdf} class="hidden" />
              <div :if={@uploads.pdf.entries == []}>
                <.icon name="hero-cloud-arrow-up" class="w-12 h-12 mx-auto text-base-content/50" />
                <p class="mt-2 text-sm text-base-content/70">
                  Drag and drop a PDF file here, or
                  <label for={@uploads.pdf.ref} class="link link-primary cursor-pointer">
                    browse
                  </label>
                </p>
              </div>
              <div :for={entry <- @uploads.pdf.entries} class="flex items-center gap-2">
                <.icon name="hero-document" class="w-8 h-8 text-primary" />
                <div class="flex-1 text-left">
                  <p class="font-medium truncate">{entry.client_name}</p>
                  <progress class="progress progress-primary w-full" value={entry.progress} max="100" />
                </div>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
              <.upload_error :for={err <- upload_errors(@uploads.pdf)} error={err} />
            </div>
          </div>

          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text">Document Title</span>
            </label>
            <input
              type="text"
              name="title"
              value={@document_title}
              placeholder="Enter document title"
              class="input input-bordered w-full"
              id="document-title-input"
            />
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
  defp error_to_string(:too_many_files), do: "Only one file can be uploaded at a time"
  defp error_to_string(:not_accepted), do: "Only PDF files are accepted"
  defp error_to_string(err), do: "Error: #{inspect(err)}"

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
    title = params["title"] || ""
    target_language = params["target_language"] || socket.assigns.target_language

    # Auto-fill title from filename if empty
    title =
      if title == "" do
        case socket.assigns.uploads.pdf.entries do
          [entry | _] ->
            entry.client_name
            |> Path.basename(".pdf")
            |> String.replace(~r/[_-]+/, " ")

          [] ->
            ""
        end
      else
        title
      end

    socket =
      socket
      |> assign(:document_title, title)
      |> assign(:target_language, target_language)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  @impl true
  def handle_event("upload_document", params, socket) do
    title = params["title"] || socket.assigns.document_title
    target_language = params["target_language"] || socket.assigns.target_language

    # Consume the uploaded file
    uploaded_files =
      consume_uploaded_entries(socket, :pdf, fn %{path: path}, entry ->
        # Create a unique filename for the PDF
        document_id = Uniq.UUID.uuid7()
        dest_dir = Documents.document_upload_dir(document_id)
        File.mkdir_p!(dest_dir)
        dest_path = Path.join(dest_dir, "original.pdf")

        # Copy the file to our uploads directory
        File.cp!(path, dest_path)

        {:ok, {document_id, entry.client_name, dest_path}}
      end)

    case uploaded_files do
      [{document_id, original_filename, pdf_path}] ->
        # Use provided title or filename
        title =
          if title == "" do
            original_filename
            |> Path.basename(".pdf")
            |> String.replace(~r/[_-]+/, " ")
          else
            title
          end

        # Create the document record
        case Documents.create_document(%{
               id: document_id,
               title: title,
               original_filename: original_filename,
               target_language: target_language,
               status: "uploading"
             }) do
          {:ok, document} ->
            # Subscribe to updates for this new document
            Logger.info("Subscribing to new document:#{document.id}")
            Phoenix.PubSub.subscribe(Doctrans.PubSub, "document:#{document.id}")

            # Start background processing
            Worker.process_document(document.id, pdf_path)

            # Refresh document list and close modal
            socket =
              socket
              |> assign(:documents, Documents.list_documents())
              |> assign(:show_upload_modal, false)
              |> assign(:document_title, "")
              |> put_flash(:info, "Document uploaded! Processing will begin shortly.")

            {:noreply, socket}

          {:error, changeset} ->
            # Clean up the uploaded file
            File.rm(pdf_path)

            socket =
              socket
              |> put_flash(:error, "Failed to create document: #{inspect(changeset.errors)}")

            {:noreply, socket}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "No file was uploaded")}
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

  # PubSub Handlers

  @impl true
  def handle_info({:document_updated, document}, socket) do
    Logger.info("Dashboard received document_updated for #{document.id}")
    # Refresh the document list to get updated statuses
    {:noreply, assign(socket, :documents, Documents.list_documents())}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    Logger.info(
      "Dashboard received page_updated for page #{page.page_number} of document #{page.document_id}"
    )

    # Refresh to update progress
    {:noreply, assign(socket, :documents, Documents.list_documents())}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.warning("Dashboard received unknown message: #{inspect(msg)}")
    {:noreply, socket}
  end
end
