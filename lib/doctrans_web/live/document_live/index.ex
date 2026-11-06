defmodule DoctransWeb.DocumentLive.Index do
  @moduledoc "Dashboard LiveView for managing documents."
  use DoctransWeb, :live_view

  alias Doctrans.Documents
  alias Doctrans.Processing.Cancellation
  alias DoctransWeb.DocumentLive.{DocumentStream, Upload, UploadReadiness}
  alias DoctransWeb.ErrorMessages
  alias DoctransWeb.PrivacyCopy

  require Logger

  import DoctransWeb.DocumentLive.Components
  import DoctransWeb.DocumentLive.UploadComponents

  # Every event `Upload` owns: the dialog and the submissions it makes. The
  # dialog is a function component, so the events it declares arrive here and
  # are forwarded verbatim.
  @upload_events ~w(
    show_upload_modal
    hide_upload_modal
    validate_upload
    cancel_upload
    upload_document
  )

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:sort_by, :inserted_at)
      |> assign(:sort_dir, :desc)
      |> Upload.init()
      |> UploadReadiness.init()
      |> DocumentStream.init()

    {:ok, DocumentStream.refresh(socket)}
  end

  @impl true
  def terminate(_reason, _socket) do
    DocumentStream.unsubscribe()
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
                <li :for={{field, dir} <- sort_options()}>
                  <button
                    type="button"
                    phx-click="sort"
                    phx-value-field={field}
                    phx-value-dir={dir}
                    class={[@sort_by == field && @sort_dir == dir && "active"]}
                  >
                    {sort_menu_label(field, dir)}
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
             until it happens to cross zero and the empty state misfires. Only
             the tests read it. --%>
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
        readiness={@readiness}
      />
    </Layouts.app>
    """
  end

  # --- Upload ----------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket) when event in @upload_events do
    Upload.handle_event(event, params, socket)
  end

  # --- Sorting ---------------------------------------------------------------

  # The event carries strings, and only a pair the menu renders is accepted: the
  # match is against the menu's own options, so nothing is turned into an atom.
  @impl true
  def handle_event("sort", %{"field" => field, "dir" => dir}, socket) do
    case Enum.find(sort_options(), &sort_option_named?(&1, field, dir)) do
      {sort_by, sort_dir} ->
        socket = assign(socket, :sort_by, sort_by) |> assign(:sort_dir, sort_dir)
        {:noreply, DocumentStream.refresh(socket)}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("sort", _params, socket), do: {:noreply, socket}

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

  defp sort_option_named?({field, dir}, field_name, dir_name),
    do: Atom.to_string(field) == field_name and Atom.to_string(dir) == dir_name

  # A card for a document another tab already deleted is gone either way.
  defp delete_existing_document(nil), do: :ok

  defp delete_existing_document(document) do
    with {:ok, _deleted} <- Cancellation.cancel_and_delete(document), do: :ok
  end

  # --- Upload readiness ------------------------------------------------------

  @impl true
  def handle_async(:upload_readiness, result, socket) do
    {:noreply, UploadReadiness.resolve(socket, result)}
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
    {:noreply, DocumentStream.page_updated(socket, page)}
  end

  @impl true
  def handle_info(:dashboard_refresh, socket) do
    {:noreply, DocumentStream.refresh_pending(socket)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.warning("Dashboard received unknown message: #{inspect(msg)}")
    {:noreply, socket}
  end
end
