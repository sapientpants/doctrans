defmodule DoctransWeb.DocumentLive.Index do
  @moduledoc "Dashboard LiveView for managing documents."
  use DoctransWeb, :live_view

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Worker
  alias Doctrans.Validation
  alias DoctransWeb.ErrorMessages

  require Logger

  import DoctransWeb.DocumentLive.Components

  @type upload_result ::
          {:ok, document_id :: Ecto.UUID.t(), filename :: String.t(), path :: String.t()}
          | {:error, filename :: String.t(), reason :: Doctrans.Errors.reason()}

  # How long to wait after a page-level update before refreshing affected cards.
  # Page updates arrive very frequently (one per page, per document); this
  # coalesces bursts while retaining a trailing refresh for every affected document.
  @refresh_coalesce_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    defaults = Application.get_env(:doctrans, :defaults, [])

    socket =
      socket
      |> assign(:document_topics, [])
      |> assign(:refresh_scheduled?, false)
      |> assign(:pending_document_ids, [])
      |> assign(:show_upload_modal, false)
      |> assign(:target_language, defaults[:target_language] || "en")
      |> assign(:sort_by, :inserted_at)
      |> assign(:sort_dir, :desc)
      |> assign(:documents_count, 0)
      |> stream(:documents, [])
      |> allow_upload(:document,
        accept: ~w(.pdf .docx .doc .odt .rtf),
        max_entries: 10,
        # max_file_size: client-side limit; the on-disk size is re-verified
        # in consume_upload_entry/2 before the file is accepted
        max_file_size: max_file_size()
      )

    if connected?(socket) do
      subscribe_to_documents_topics(socket.assigns.document_topics)
    end

    {:ok, refresh_list(socket)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Unsubscribe from the pubsub topics we registered for, so the client
    # process doesn't accumulate subscriptions across visits.
    unsubscribe_from_documents_topics(socket.assigns.document_topics)
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
    {:noreply, refresh_list(socket)}
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
          |> remove_document(id)

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
        consume_upload_entry(path, entry)
      end)

    {valid_files, rejected} = Enum.split_with(uploaded_files, &successful_upload?/1)

    handle_upload_results(socket, valid_files, rejected, target_language)
  end

  @spec successful_upload?(upload_result()) :: boolean()
  defp successful_upload?({:ok, _document_id, _filename, _path}), do: true
  defp successful_upload?({:error, _filename, _reason}), do: false

  # LiveView unwraps the outer :ok, leaving an upload_result for each consumed file.
  @spec consume_upload_entry(binary(), Phoenix.LiveView.UploadEntry.t()) :: {:ok, upload_result()}
  # Source: LiveView temp metadata. Destination: generated UUID + original + magic-byte-validated extension.
  # sobelow_skip ["Traversal.FileModule"]
  defp consume_upload_entry(path, entry) do
    extension = entry.client_name |> Path.extname() |> String.downcase()
    max_file_size = max_file_size()

    with :ok <- validate_disk_size(path, max_file_size),
         :ok <- Validation.validate_file_content(path, extension) do
      document_id = Uniq.UUID.uuid7()
      dest_dir = Documents.document_upload_dir(document_id)
      File.mkdir_p!(dest_dir)

      dest_path = Path.join(dest_dir, "original#{extension}")
      File.cp!(path, dest_path)
      {:ok, {:ok, document_id, entry.client_name, dest_path}}
    else
      {:error, reason} ->
        Logger.warning("Upload rejected for #{entry.client_name}: #{inspect(reason)}")
        {:ok, {:error, entry.client_name, reason}}
    end
  end

  @spec max_file_size() :: pos_integer()
  defp max_file_size do
    Uploads.max_file_size()
  end

  # The client-side allow_upload size limit is not a security boundary;
  # verify the actual size of the file on disk before accepting it.
  @spec validate_disk_size(binary(), pos_integer()) :: :ok | {:error, Doctrans.Errors.reason()}
  defp validate_disk_size(path, max_size) do
    path = to_string(path)

    case File.stat(path, size: true) do
      {:ok, %{size: size}} when size <= max_size ->
        :ok

      {:ok, %{size: size}} ->
        {:error, {:file_too_large, [size: div(size, 1_000_000), max: div(max_size, 1_000_000)]}}

      {:error, _} ->
        {:error, :upload_unreadable}
    end
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
      create_and_process_document({document_id, client_name, dest_path}, target_language)
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
      |> refresh_list()

    socket =
      if rejected != [] do
        rejected_names =
          Enum.map_join(rejected, ", ", fn {:error, name, _reason} -> name end)

        put_flash(
          socket,
          :warning,
          gettext("Some files were rejected: %{names}", names: rejected_names)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  # Helper to create a document and start processing
  # The cleanup path is returned by consume_upload_entry, never built from the display filename.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_and_process_document({document_id, original_filename, pdf_path}, target_language) do
    original_filename = Validation.sanitize_filename_string(original_filename)

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
        Logger.debug("Dashboard now tracking new document:#{document.id}")
        _ = subscribe_to_document_topic(document.id)
        _ = Worker.process_document(document.id, pdf_path)

      {:error, changeset} ->
        Logger.error("Failed to create document: #{inspect(changeset)}")
        File.rm(pdf_path)
    end
  end

  # --- PubSub: progress updates ----------------------------------------------

  @impl true
  def handle_info({:document_updated, document}, socket) do
    Logger.debug("Dashboard received document_updated for #{document.id}")
    {:noreply, refresh_documents(socket, [document.id])}
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
       |> refresh_documents([page.document_id])}
    end
  end

  @impl true
  def handle_info(:dashboard_refresh, socket) do
    ids = socket.assigns.pending_document_ids

    {:noreply,
     socket
     |> assign(:refresh_scheduled?, false)
     |> assign(:pending_document_ids, [])
     |> refresh_documents(ids)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.warning("Dashboard received unknown message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # --- List refresh ----------------------------------------------------------

  # Re-queries the document list, resets the stream, and keeps the socket
  # subscribed to the (global) document topics it needs to receive updates.
  defp refresh_list(socket) do
    documents =
      Documents.list_documents_with_progress(
        sort_by: socket.assigns.sort_by,
        sort_dir: socket.assigns.sort_dir
      )

    topics = Enum.map(documents, & &1.id)

    if connected?(socket) do
      unsubscribe_from_documents_topics(socket.assigns.document_topics -- topics)
      subscribe_to_documents_topics(topics -- socket.assigns.document_topics)
    end

    socket
    |> assign(:document_topics, topics)
    |> assign(:document_order, Enum.map(documents, &order_entry(&1, socket)))
    |> assign(:documents_count, length(documents))
    |> stream(:documents, documents, reset: true)
  end

  # Keys detect changes; PostgreSQL determines ordering, including title collation.
  defp order_entry(summary, socket) do
    {summary.id, Map.fetch!(summary.document, socket.assigns.sort_by)}
  end

  defp refresh_documents(socket, []), do: socket

  defp refresh_documents(socket, ids) do
    summaries = Documents.list_documents_with_progress(document_ids: ids)
    found_ids = Enum.map(summaries, & &1.id)
    socket = Enum.reduce(ids -- found_ids, socket, &remove_document(&2, &1))
    update_documents(socket, summaries)
  end

  defp update_documents(socket, summaries) do
    previous_order = socket.assigns.document_order
    order = updated_document_order(socket, summaries)

    # The client applies all deletions before insertions. Remove affected cards
    # together, then reinsert from left to right at their final batch positions.
    socket =
      if order != previous_order do
        Enum.reduce(summaries, socket, &stream_delete(&2, :documents, &1))
      else
        socket
      end

    topics = Enum.map(order, &elem(&1, 0))

    if connected?(socket),
      do: subscribe_to_documents_topics(topics -- socket.assigns.document_topics)

    socket =
      socket
      |> assign(:document_order, order)
      |> assign(:documents_count, length(order))
      |> assign(:document_topics, topics)

    summaries_by_id = Map.new(summaries, &{&1.id, &1})

    order
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {{id, _key}, index}, socket ->
      case Map.fetch(summaries_by_id, id) do
        {:ok, summary} -> stream_insert(socket, :documents, summary, at: index)
        :error -> socket
      end
    end)
  end

  defp updated_document_order(socket, summaries) do
    previous_order = socket.assigns.document_order
    previous_keys = Map.new(previous_order)
    entries = Map.new(summaries, &order_entry(&1, socket))

    if Enum.any?(entries, fn {id, key} -> Map.fetch(previous_keys, id) != {:ok, key} end) do
      previous_keys
      |> Map.merge(entries)
      |> Map.to_list()
      |> Documents.sort_document_order(
        sort_by: socket.assigns.sort_by,
        sort_dir: socket.assigns.sort_dir
      )
    else
      previous_order
    end
  end

  defp remove_document(socket, id) do
    if connected?(socket), do: Topics.unsubscribe_document(id)
    order = Enum.reject(socket.assigns.document_order, &(elem(&1, 0) == id))

    socket
    |> assign(:document_order, order)
    |> assign(:documents_count, length(order))
    |> assign(:document_topics, Enum.reject(socket.assigns.document_topics, &(&1 == id)))
    |> assign(
      :pending_document_ids,
      Enum.reject(socket.assigns.pending_document_ids, &(&1 == id))
    )
    |> stream_delete(:documents, %{id: id})
  end

  defp subscribe_to_documents_topics(topics) do
    Enum.each(topics, fn document_id ->
      Topics.subscribe_document(document_id)
    end)
  end

  defp unsubscribe_from_documents_topics(topics) do
    Enum.each(topics, fn document_id ->
      Topics.unsubscribe_document(document_id)
    end)
  end

  defp subscribe_to_document_topic(document_id) do
    Topics.subscribe_document(document_id)
  end
end
