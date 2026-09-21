defmodule DoctransWeb.DocumentLive.Index do
  @moduledoc "Dashboard LiveView for managing documents."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.Worker
  alias DoctransWeb.DocumentLive.DocumentStream
  alias DoctransWeb.DocumentLive.UploadIntake
  alias DoctransWeb.DocumentLive.UploadOutcomes
  alias DoctransWeb.ErrorMessages
  alias DoctransWeb.PrivacyCopy

  require Logger

  import DoctransWeb.DocumentLive.Components
  import DoctransWeb.DocumentLive.UploadComponents

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
      |> assign(:upload_failures, [])
      |> assign(:upload_pending, [])
      |> assign(:upload_started, 0)
      |> assign(:source_language, defaults[:source_language] || "de")
      |> assign(:target_language, defaults[:target_language] || "en")
      |> assign(:sort_by, :inserted_at)
      |> assign(:sort_dir, :desc)
      |> DocumentStream.init()
      |> allow_upload(:document,
        accept: ~w(.pdf .docx .doc .odt .rtf),
        max_entries: UploadIntake.max_entries(),
        # max_file_size: client-side limit; the on-disk size is re-verified
        # in UploadIntake.consume_entry/2 before the file is accepted
        max_file_size: UploadIntake.max_file_size()
      )

    _ = if connected?(socket), do: Topics.subscribe_documents()

    {:ok, DocumentStream.refresh(socket)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    # Unsubscribe from the collection topic we registered for, so the client
    # process doesn't accumulate subscriptions across visits.
    Topics.unsubscribe_documents()
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="w-full px-8 py-8">
        <%!-- Wraps like the Show header: this row carries the search field,
             the sort control, Upload and the theme toggle, which together
             overflow a fixed row well before the narrowest supported width. --%>
        <div class="flex flex-wrap justify-between items-center gap-x-4 gap-y-3 mb-6">
          <div>
            <h1 class="text-3xl font-bold text-base-content">{gettext("Doctrans")}</h1>
            <p id="privacy-tagline" class="text-base-content/70 mt-1">
              {PrivacyCopy.tagline()}
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <%!-- Inline search form --%>
            <form
              action="/search"
              method="get"
              role="search"
              class="relative"
              id="dashboard-search-form"
            >
              <label for="dashboard-search-input" class="sr-only">
                {gettext("Search documents")}
              </label>
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
              <%!-- A real `<button>`, not a `<label tabindex="0">`: daisyUI opens the
                    dropdown from CSS `:focus-within`, which a button satisfies just as
                    well, and a bare label is announced as nothing at all.

                    This is a disclosure, not a menu. `aria-haspopup="menu"` would
                    promise arrow-key navigation between `menuitem`s that nothing here
                    implements, so the trigger only claims what it delivers: it controls
                    a group of buttons, and says whether that group is showing.
                    `aria-expanded` is mirrored from focus by `DropdownExpanded`, since
                    the open state lives entirely in CSS. --%>
              <button
                type="button"
                id="sort-documents-trigger"
                phx-hook="DropdownExpanded"
                aria-expanded="false"
                aria-controls="sort-documents-menu"
                aria-label={gettext("Sort documents")}
                class="btn btn-sm btn-ghost gap-1.5 text-base-content/70"
              >
                <.icon name="hero-arrows-up-down" class="w-4 h-4" />
                <span class="text-xs font-normal">{sort_label(@sort_by, @sort_dir)}</span>
              </button>
              <ul
                tabindex="0"
                id="sort-documents-menu"
                class="dropdown-content z-10 menu menu-sm p-1 shadow-lg bg-base-200 rounded-lg w-40 mt-1"
              >
                <li>
                  <button
                    type="button"
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
                    type="button"
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
                    type="button"
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
                    type="button"
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

            <Layouts.theme_toggle />
          </div>
        </div>

        <%!-- Sits outside the `phx-update="stream"` container on purpose: the client
             refuses to discard an id-bearing child of a stream container, and a stream
             reset only removes children carrying `data-phx-stream`. Moved back inside,
             "No documents yet" would stay on screen underneath the first card that
             arrives -- from this tab or another one. --%>
        <div :if={@documents_count == 0} id="documents-empty" class="text-center py-16">
          <.icon name="hero-document-text" class="w-16 h-16 mx-auto text-base-content/30" />
          <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("No documents yet")}</h3>
          <p class="mt-2 text-base-content/70">
            {PrivacyCopy.empty_state()}
          </p>
        </div>

        <%!-- `data-documents-count` publishes the assign the empty state above is
             driven by. It is the one piece of list state the page cannot show on
             its own -- a stream is not countable from the DOM alone -- and without
             it a count that drifts away from the cards on screen stays invisible
             until it happens to cross zero and the empty state misfires. --%>
        <div
          id="documents"
          data-documents-count={@documents_count}
          phx-update="stream"
          class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6 gap-6"
        >
          <div :for={{id, document} <- @streams.documents} id={id}>
            <.document_card summary={document} />
          </div>
        </div>
      </div>

      <.upload_modal
        :if={@show_upload_modal}
        return_focus="#upload-document-btn"
        uploads={@uploads}
        source_language={@source_language}
        target_language={@target_language}
        failures={@upload_failures}
        pending={@upload_pending}
        started={@upload_started}
      />
    </Layouts.app>
    """
  end

  # --- Upload modal ----------------------------------------------------------

  @impl true
  def handle_event("show_upload_modal", _params, socket),
    do: {:noreply, socket |> assign(:show_upload_modal, true) |> UploadOutcomes.clear()}

  @impl true
  def handle_event("hide_upload_modal", _params, socket),
    do: {:noreply, assign(socket, :show_upload_modal, false)}

  @impl true
  def handle_event("validate_upload", params, socket) do
    source_language = params["source_language"] || socket.assigns.source_language
    target_language = params["target_language"] || socket.assigns.target_language

    socket =
      socket
      |> assign(:source_language, source_language)
      |> assign(:target_language, target_language)

    # Picking files again is the retry the failure list asks for, so the list of
    # what failed last time goes with the submission it described. This event also
    # fires for the language selects, which are not that retry: clearing there
    # would take the explanation away from a user who is still reading it.
    socket =
      if params["_target"] == ["document"],
        do: UploadOutcomes.clear(socket),
        else: socket

    {:noreply, socket}
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
    source_language = params["source_language"] || socket.assigns.source_language
    target_language = params["target_language"] || socket.assigns.target_language

    case UploadIntake.validate_languages(source_language, target_language) do
      {:ok, languages} ->
        upload_documents_with_validated_languages(socket, languages)

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

  # One pass over the entries in the order the user picked them, so the outcome list
  # reads the same way the drop zone above it does. Entries are consumed one at a
  # time rather than through `consume_uploaded_entries/3`, which takes the whole
  # config at once and raises while any entry is still pending -- that is how one
  # file the browser rejected took the outcome of every file beside it down with
  # the socket.
  defp upload_documents_with_validated_languages(socket, languages) do
    upload = socket.assigns.uploads.document

    {socket, outcomes} =
      Enum.reduce(upload.entries, {socket, []}, fn entry, {socket, acc} ->
        {socket, outcome} = process_entry(socket, upload, entry, languages)
        {socket, [outcome | acc]}
      end)

    {:noreply, UploadOutcomes.report(socket, Enum.reverse(outcomes))}
  end

  # One entry's whole journey, so that its place in the report is its place in the
  # list the user is looking at.
  defp process_entry(socket, upload, entry, languages) do
    cond do
      not entry.valid? ->
        # Cancelled so it stops blocking the config it sits in; its reason travels
        # in the outcome list instead.
        {cancel_upload(socket, :document, entry.ref),
         {:error, entry.client_name,
          UploadIntake.entry_reason(upload_errors(upload, entry), entry)}}

      not entry.done? ->
        # Still on its way. Left in the modal for the submission that finishes it,
        # and reported so it is never silently dropped from a submission that
        # otherwise succeeded.
        {socket, {:pending, entry.client_name}}

      true ->
        {socket, start_entry(socket, entry, languages)}
    end
  end

  defp start_entry(socket, entry, languages) do
    consumed =
      consume_uploaded_entry(socket, entry, fn meta ->
        # `meta` is an opaque map from LiveView; coerce the path to a string
        # so the type stays concrete for downstream File calls.
        path = to_string(Map.get(meta, :path, ""))
        UploadIntake.consume_entry(path, entry)
      end)

    if UploadIntake.accepted?(consumed) do
      UploadIntake.create_and_process(consumed, languages)
    else
      consumed
    end
  end

  # --- PubSub: progress updates ----------------------------------------------

  @impl true
  def handle_info({:document_updated, document}, socket) do
    Logger.debug("Dashboard received document_updated for #{document.id}")
    {:noreply, DocumentStream.refresh_documents(socket, [document.id])}
  end

  # Another tab's upload. Refreshing this one id folds the new card into the stream
  # in its sorted position; the tab that did the uploading has already refreshed and
  # gets the same card back unchanged.
  @impl true
  def handle_info({:document_created, document}, socket) do
    Logger.debug("Dashboard received document_created for #{document.id}")
    {:noreply, DocumentStream.refresh_documents(socket, [document.id])}
  end

  # Likewise for a deletion: the deleting tab has already removed the card, and
  # removing an id that is no longer tracked is a no-op.
  @impl true
  def handle_info({:document_deleted, document_id}, socket) do
    Logger.debug("Dashboard received document_deleted for #{document_id}")
    {:noreply, DocumentStream.remove(socket, document_id)}
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
