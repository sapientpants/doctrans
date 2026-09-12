defmodule DoctransWeb.DocumentLive.Index do
  @moduledoc "Dashboard LiveView for managing documents."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Processing.Worker
  alias Doctrans.Validation
  alias DoctransWeb.DocumentLive.DocumentStream
  alias DoctransWeb.DocumentLive.UploadIntake
  alias DoctransWeb.ErrorMessages

  require Logger

  import DoctransWeb.DocumentLive.Components

  # How long to wait after a page-level update before refreshing affected cards.
  # Page updates arrive very frequently (one per page, per document); this
  # coalesces bursts while retaining a trailing refresh for every affected document.
  @refresh_coalesce_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    defaults = Application.get_env(:doctrans, :defaults, [])

    socket =
      socket
      |> assign(:refresh_scheduled?, false)
      |> assign(:pending_document_ids, [])
      |> assign(:show_upload_modal, false)
      |> assign(:target_language, defaults[:target_language] || "en")
      |> assign(:sort_by, :inserted_at)
      |> assign(:sort_dir, :desc)
      |> DocumentStream.init()
      |> allow_upload(:document,
        accept: ~w(.pdf .docx .doc .odt .rtf),
        max_entries: 10,
        # max_file_size: client-side limit; the on-disk size is re-verified
        # in UploadIntake.consume_entry/2 before the file is accepted
        max_file_size: UploadIntake.max_file_size()
      )

    if connected?(socket) do
      DocumentStream.subscribe(socket.assigns.document_topics)
    end

    {:ok, DocumentStream.refresh(socket)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Unsubscribe from the pubsub topics we registered for, so the client
    # process doesn't accumulate subscriptions across visits.
    DocumentStream.unsubscribe(socket.assigns.document_topics)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="w-full px-8 py-8">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold text-base-content">{gettext("Doctrans")}</h1>
            <p class="text-base-content/70 mt-1">
              {gettext("Private document translation powered by local AI")}
            </p>
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

        <div
          id="documents"
          phx-update="stream"
          class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6 gap-6"
        >
          <div
            :if={@documents_count == 0}
            id="documents-empty"
            class="text-center py-16 col-span-full"
          >
            <.icon name="hero-document-text" class="w-16 h-16 mx-auto text-base-content/30" />
            <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("No documents yet")}</h3>
            <p class="mt-2 text-base-content/70">
              {gettext(
                "Upload a document to get started. All processing happens locally on your device."
              )}
            </p>
          </div>
          <div :for={{id, document} <- @streams.documents} id={id}>
            <.document_card summary={document} />
          </div>
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

  # --- Upload modal ----------------------------------------------------------

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
    do: {:noreply, cancel_upload(socket, :document, ref)}

  # --- Sorting ---------------------------------------------------------------

  @allowed_sort_fields ~w(inserted_at title)
  @allowed_sort_dirs ~w(asc desc)

  @impl true
  def handle_event("sort", %{"field" => field, "dir" => dir}, socket)
      when field in @allowed_sort_fields and dir in @allowed_sort_dirs do
    sort_by = String.to_existing_atom(field)
    sort_dir = String.to_existing_atom(dir)

    socket = assign(socket, :sort_by, sort_by) |> assign(:sort_dir, sort_dir)
    {:noreply, DocumentStream.refresh(socket)}
  end

  @impl true
  def handle_event("sort", _params, socket), do: {:noreply, socket}

  # --- Document upload -------------------------------------------------------

  @impl true
  def handle_event("upload_document", params, socket) do
    target_language = params["target_language"] || socket.assigns.target_language

    # Validate target language
    case Validation.validate_language(target_language) do
      {:ok, validated_language} ->
        upload_documents_with_validated_language(socket, validated_language)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, ErrorMessages.message(reason))}
    end
  end

  # --- Document deletion -----------------------------------------------------

  @impl true
  def handle_event("delete_document", %{"id" => id}, socket) do
    case delete_existing_document(Documents.get_document(id)) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, gettext("Document deleted successfully"))
          |> DocumentStream.remove(id)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, ErrorMessages.message(:delete_failed))}
    end
  end

  defp delete_existing_document(nil), do: :ok

  defp delete_existing_document(document) do
    with :ok <- Worker.cancel_document(document.id),
         {:ok, _} <- Documents.delete_document(document) do
      :ok
    end
  end

  defp upload_documents_with_validated_language(socket, target_language) do
    uploaded_files =
      consume_uploaded_entries(socket, :document, fn meta, entry ->
        # `meta` is an opaque map from LiveView; coerce the path to a string
        # so the type stays concrete for downstream File calls.
        path = to_string(Map.get(meta, :path, ""))
        UploadIntake.consume_entry(path, entry)
      end)

    {valid_files, rejected} = Enum.split_with(uploaded_files, &UploadIntake.accepted?/1)

    handle_upload_results(socket, valid_files, rejected, target_language)
  end

  defp handle_upload_results(socket, [], [_ | _], _target_language) do
    {:noreply,
     put_flash(socket, :error, gettext("No valid files were uploaded. Check file formats."))}
  end

  defp handle_upload_results(socket, [], [], _target_language) do
    {:noreply, put_flash(socket, :error, gettext("No files were uploaded"))}
  end

  defp handle_upload_results(socket, valid_files, rejected, target_language) do
    Enum.each(valid_files, fn {:ok, document_id, client_name, dest_path} ->
      UploadIntake.create_and_process(
        {document_id, client_name, dest_path},
        target_language
      )
    end)

    message =
      ngettext(
        "Document uploaded! Processing will begin shortly.",
        "%{count} documents uploaded! Processing will begin shortly.",
        length(valid_files)
      )

    socket =
      socket
      |> assign(:show_upload_modal, false)
      |> put_flash(:info, message)
      |> DocumentStream.refresh()

    {:noreply, warn_about_rejected(socket, rejected)}
  end

  defp warn_about_rejected(socket, []), do: socket

  defp warn_about_rejected(socket, rejected) do
    names = Enum.map_join(rejected, ", ", fn {:error, name, _reason} -> name end)
    put_flash(socket, :warning, gettext("Some files were rejected: %{names}", names: names))
  end

  # --- PubSub: progress updates ----------------------------------------------

  @impl true
  def handle_info({:document_updated, document}, socket) do
    Logger.debug("Dashboard received document_updated for #{document.id}")
    {:noreply, DocumentStream.refresh_documents(socket, [document.id])}
  end

  @impl true
  def handle_info({:page_updated, page}, socket) do
    if socket.assigns.refresh_scheduled? do
      ids = Enum.uniq([page.document_id | socket.assigns.pending_document_ids])
      {:noreply, assign(socket, :pending_document_ids, ids)}
    else
      Process.send_after(self(), :dashboard_refresh, @refresh_coalesce_ms)

      {:noreply,
       socket
       |> assign(:refresh_scheduled?, true)
       |> DocumentStream.refresh_documents([page.document_id])}
    end
  end

  @impl true
  def handle_info(:dashboard_refresh, socket) do
    ids = socket.assigns.pending_document_ids

    {:noreply,
     socket
     |> assign(:refresh_scheduled?, false)
     |> assign(:pending_document_ids, [])
     |> DocumentStream.refresh_documents(ids)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.warning("Dashboard received unknown message: #{inspect(msg)}")
    {:noreply, socket}
  end
end
