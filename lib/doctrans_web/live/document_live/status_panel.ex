defmodule DoctransWeb.DocumentLive.StatusPanel do
  @moduledoc """
  Translation state, and the targeted recovery actions for both pipelines.

  Only translation states itself in prose. Indexing is reported by its recovery
  button alone: a steady "search ready" readout was chrome the whole time it was
  right, and it counted only the pages extracted so far, so mid-run it called a
  half-indexed document complete. The row carries its machine state on a
  `data-` attribute so the assertion is on the state, not on prose that every
  locale rewrites.
  """
  use DoctransWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Doctrans.Documents.ProcessingStatus
  alias Doctrans.Processing.{Cancellation, DocumentReprocessing}
  alias Doctrans.Search.Reindex
  alias DoctransWeb.ErrorMessages

  @doc "Assigns the document's processing status for the first time."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: refresh(socket)

  @doc """
  Recomputes the status from the current document.

  Called from the debounced progress refresh, which already runs on mount and
  on every `{:document_updated, _}` and `{:page_updated, _}`, so the panel
  follows the pipelines live without a subscription of its own.
  """
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(%{assigns: %{document: nil}} = socket), do: socket

  def refresh(socket) do
    assign(socket, :processing_status, ProcessingStatus.for_document(socket.assigns.document))
  end

  # Each action is re-authorized against a status read here, not against the
  # markup: an event arrives over the socket whether or not its button was
  # rendered, and the rendered flags are as old as the last refresh. The domain
  # functions refuse too, but a UI that relies on that has no answer for the
  # day a refusal is relaxed -- and `Reindex.retry_document/1` has no refusal to
  # rely on at all, since re-queueing an already-ready index is legal and would
  # report "queued 0 pages" to a user who was offered no button.
  def handle_event("retry_indexing", _params, socket) do
    {:noreply, act(socket, & &1.retry_index?, &retry_indexing/1)}
  end

  def handle_event("retry_failed_pages", _params, socket) do
    {:noreply, act(socket, & &1.retry_pages?, &retry_failed_pages/1)}
  end

  def handle_event("cancel_processing", _params, socket) do
    {:noreply, act(socket, & &1.cancellable?, &cancel_processing/1)}
  end

  defp act(socket, allowed?, run) do
    document = socket.assigns.document
    status = ProcessingStatus.for_document(document)

    if allowed?.(status) do
      socket |> put_outcome(run.(document)) |> refresh()
    else
      assign(socket, :processing_status, status)
    end
  end

  # Every action reports what it did rather than that it was accepted: "queued
  # 3 pages" is the difference between a recovery the user can trust and a
  # button that blinks.
  defp retry_indexing(document) do
    with {:ok, count} <- Reindex.retry_document(document) do
      {:ok,
       ngettext(
         "Queued %{count} page for indexing",
         "Queued %{count} pages for indexing",
         count,
         count: count
       )}
    end
  end

  defp retry_failed_pages(document) do
    with {:ok, count} <- DocumentReprocessing.retry_failed_pages(document.id) do
      {:ok,
       ngettext(
         "Queued %{count} failed page for translation",
         "Queued %{count} failed pages for translation",
         count,
         count: count
       )}
    end
  end

  defp cancel_processing(document) do
    with {:ok, _document} <- Cancellation.cancel_document(document) do
      {:ok, gettext("Processing stopped. Translated pages were kept.")}
    end
  end

  defp put_outcome(socket, {:ok, message}), do: put_flash(socket, :info, message)

  defp put_outcome(socket, {:error, reason}),
    do: put_flash(socket, :error, ErrorMessages.message(reason))

  attr :status, ProcessingStatus, required: true

  def status_panel(assigns) do
    ~H"""
    <section
      id="processing-status"
      aria-label={gettext("Processing status")}
      class="border-b border-base-300 bg-base-100 px-4 py-3"
    >
      <div class="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-start sm:justify-between">
        <div class="min-w-0 flex-1">
          <div
            id="processing-status-content"
            data-content-state={to_string(@status.content)}
            class="min-w-0 space-y-1"
          >
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-xs font-medium uppercase tracking-wide text-base-content/60">
                {gettext("Translation")}
              </span>
              <span class={["badge badge-sm", content_badge(@status.content)]}>
                {content_label(@status.content)}
              </span>
              <span
                :if={@status.failed_page_count > 0}
                id="processing-status-failed-count"
                data-failed-page-count={@status.failed_page_count}
                class="badge badge-sm badge-error badge-outline"
              >
                {ngettext("%{count} failed page", "%{count} failed pages", @status.failed_page_count,
                  count: @status.failed_page_count
                )}
              </span>
            </div>
            <p
              :if={@status.failed_page_count > 0}
              id="processing-status-failed-pages"
              data-failed-pages={Enum.join(@status.failed_pages, ",")}
              class="text-xs text-error"
            >
              {ErrorMessages.message(
                {:pages_failed, [page_numbers: Enum.join(@status.failed_pages, ", ")]}
              )}
            </p>
          </div>
        </div>

        <div
          :if={@status.retry_index? or @status.retry_pages? or @status.cancellable?}
          id="processing-status-actions"
          class="flex flex-wrap items-center gap-2"
        >
          <button
            :if={@status.retry_index?}
            id="retry-indexing"
            type="button"
            phx-click="retry_indexing"
            phx-disable-with={gettext("Queuing…")}
            class={action_class()}
          >
            <.icon name="hero-magnifying-glass-circle" class="size-4 shrink-0" />
            {gettext("Retry indexing")}
          </button>
          <button
            :if={@status.retry_pages?}
            id="retry-failed-pages"
            type="button"
            phx-click="retry_failed_pages"
            phx-disable-with={gettext("Queuing…")}
            class={action_class()}
          >
            <.icon name="hero-arrow-path" class="size-4 shrink-0" />
            {gettext("Retry failed pages")}
          </button>
          <button
            :if={@status.cancellable?}
            id="cancel-processing"
            type="button"
            phx-click="cancel_processing"
            phx-disable-with={gettext("Stopping…")}
            class={[action_class(), "text-error hover:bg-error/10"]}
          >
            <.icon name="hero-stop-circle" class="size-4 shrink-0" />
            {gettext("Stop processing")}
          </button>
        </div>
      </div>
    </section>
    """
  end

  # A string, not a list: a nested list inside a `class={[...]}` attribute is not
  # flattened, so the variant button below would render its shared classes as one
  # unusable token.
  defp action_class do
    "inline-flex items-center gap-2 rounded-lg border border-base-300 px-3 py-2 text-sm " <>
      "font-medium transition-colors hover:bg-base-300 focus-visible:outline-2 " <>
      "focus-visible:outline-offset-2 focus-visible:outline-primary " <>
      "disabled:cursor-not-allowed disabled:opacity-40"
  end

  defp content_label(:idle), do: gettext("Idle")
  defp content_label(:queued), do: gettext("Queued")
  defp content_label(:running), do: gettext("Processing")
  defp content_label(:retrying), do: gettext("Retrying")
  defp content_label(:failed), do: gettext("Failed")
  defp content_label(:completed), do: gettext("Completed")
  defp content_label(:cancelled), do: gettext("Stopped")

  defp content_badge(:completed), do: "badge-success"
  defp content_badge(:failed), do: "badge-error"
  defp content_badge(:running), do: "badge-warning"
  defp content_badge(:retrying), do: "badge-warning"
  defp content_badge(:queued), do: "badge-info"
  defp content_badge(_state), do: "badge-ghost"
end
