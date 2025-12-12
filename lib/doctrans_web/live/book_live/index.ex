defmodule DoctransWeb.DocumentLive.Index do
  @moduledoc "Dashboard LiveView for managing documents."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker
  alias Doctrans.Validation

  require Logger

  import DoctransWeb.DocumentLive.Components

  @impl true
  def mount(_params, _session, socket) do
    documents = Documents.list_documents_with_progress()
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
      # Sort state
      |> assign(:sort_by, :inserted_at)
      |> assign(:sort_dir, :desc)
      |> allow_upload(:pdf,
        accept: ~w(.pdf),
        max_entries: 10,
        max_file_size: Application.get_env(:doctrans, :uploads)[:max_file_size] || 100_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="w-full px-8 py-8">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold text-base-content">{gettext("Doctrans")}</h1>
            <p class="text-base-content/70 mt-1">{gettext("PDF Document Translator")}</p>
          </div>
          <div class="flex items-center gap-3">
            <%!-- Inline search form --%>
            <form action="/search" method="get" class="relative" id="dashboard-search-form">
              <.icon
                name="hero-magnifying-glass"
                class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 z-10 text-base-content/60 pointer-events-none"
              />
              <input
                type="text"
                name="q"
                placeholder={gettext("Search...")}
                class="input input-bordered input-sm w-48 pl-9 pr-3"
                id="dashboard-search-input"
              />
            </form>

            <%!-- Sort dropdown --%>
            <div class="dropdown dropdown-end">
              <label tabindex="0" class="btn btn-sm btn-ghost gap-1.5 text-base-content/70">
                <.icon name="hero-arrows-up-down" class="w-4 h-4" />
                <span class="text-xs font-normal">{sort_label(@sort_by, @sort_dir)}</span>
              </label>
              <ul
                tabindex="0"
                class="dropdown-content z-10 menu menu-sm p-1 shadow-lg bg-base-200 rounded-lg w-40 mt-1"
              >
                <li>
                  <button
                    phx-click="sort"
                    phx-value-field="inserted_at"
                    phx-value-dir="desc"
                    class={[@sort_by == :inserted_at && @sort_dir == :desc && "active"]}
                  >
                    {gettext("Newest First")}
                  </button>
                </li>
                <li>
                  <button
                    phx-click="sort"
                    phx-value-field="inserted_at"
                    phx-value-dir="asc"
                    class={[@sort_by == :inserted_at && @sort_dir == :asc && "active"]}
                  >
                    {gettext("Oldest First")}
                  </button>
                </li>
                <li>
                  <button
                    phx-click="sort"
                    phx-value-field="title"
                    phx-value-dir="asc"
                    class={[@sort_by == :title && @sort_dir == :asc && "active"]}
                  >
                    {gettext("Name (A-Z)")}
                  </button>
                </li>
                <li>
                  <button
                    phx-click="sort"
                    phx-value-field="title"
                    phx-value-dir="desc"
                    class={[@sort_by == :title && @sort_dir == :desc && "active"]}
                  >
                    {gettext("Name (Z-A)")}
                  </button>
                </li>
              </ul>
            </div>

            <%!-- Upload button --%>
            <button
              type="button"
              phx-click="show_upload_modal"
              class="btn btn-primary btn-sm"
              id="upload-document-btn"
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Upload")}
            </button>
          </div>
        </div>

        <div :if={@documents == []} class="text-center py-16">
          <.icon name="hero-document-text" class="w-16 h-16 mx-auto text-base-content/30" />
          <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("No documents yet")}</h3>
          <p class="mt-2 text-base-content/70">
            {gettext("Upload a PDF to get started with translation.")}
          </p>
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

  @impl true
  def handle_event("show_upload_modal", _params, socket),
    do: {:noreply, assign(socket, :show_upload_modal, true)}

  @impl true
  def handle_event("hide_upload_modal", _params, socket),
    do: {:noreply, assign(socket, :show_upload_modal, false)}

  @impl true
  def handle_event("validate_upload", params, socket) do
    target_language = params["target_language"] || socket.assigns.target_language
    {:noreply, assign(socket, :target_language, target_language)}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :pdf, ref)}

  @impl true
  def handle_event("sort", %{"field" => field, "dir" => dir}, socket) do
    sort_by = String.to_existing_atom(field)
    sort_dir = String.to_existing_atom(dir)
    documents = Documents.list_documents_with_progress(sort_by: sort_by, sort_dir: sort_dir)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:documents, documents)}
  end

  @impl true
  def handle_event("upload_document", params, socket) do
    target_language = params["target_language"] || socket.assigns.target_language

    # Validate target language
    case Validation.validate_language(target_language) do
      {:ok, validated_language} ->
        upload_documents_with_validated_language(socket, validated_language)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Invalid language: #{reason}")}
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
          |> assign(:documents, Documents.list_documents_with_progress())
          |> put_flash(:info, gettext("Document deleted successfully"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete document"))}
    end
  end

  # Private function to handle document upload with validated language
  defp upload_documents_with_validated_language(socket, target_language) do
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
        {:noreply, put_flash(socket, :error, gettext("No files were uploaded"))}

      files ->
        # Create a document for each uploaded file
        Enum.each(files, fn file_info ->
          create_and_process_document(file_info, target_language)
        end)

        file_count = length(files)

        message =
          ngettext(
            "Document uploaded! Processing will begin shortly.",
            "%{count} documents uploaded! Processing will begin shortly.",
            count: file_count
          )

        {:noreply,
         socket
         |> assign(:show_upload_modal, false)
         |> assign(:documents, Documents.list_documents_with_progress())
         |> put_flash(:info, message)}
    end
  end

  # Helper to create a document and start processing
  defp create_and_process_document({document_id, original_filename, pdf_path}, target_language) do
    title =
      original_filename
      |> Path.basename(".pdf")
      |> String.replace(~r/[_-]+/, " ")

    attrs = %{
      id: document_id,
      title: title,
      original_filename: original_filename,
      target_language: target_language,
      status: "uploading"
    }

    case Documents.create_document(attrs) do
      {:ok, document} ->
        Logger.info("Subscribing to new document:#{document.id}")
        Phoenix.PubSub.subscribe(Doctrans.PubSub, "document:#{document.id}")
        Worker.process_document(document.id, pdf_path)

      {:error, changeset} ->
        Logger.error("Failed to create document: #{inspect(changeset)}")
        File.rm(pdf_path)
    end
  end

  @impl true
  def handle_info({:document_updated, document}, socket) do
    Logger.info("Dashboard received document_updated for #{document.id}")
    {:noreply, assign(socket, :documents, Documents.list_documents_with_progress())}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    Logger.info(
      "Dashboard received page_updated for page #{page.page_number} of document #{page.document_id}"
    )

    {:noreply, assign(socket, :documents, Documents.list_documents_with_progress())}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.warning("Dashboard received unknown message: #{inspect(msg)}")
    {:noreply, socket}
  end
end
