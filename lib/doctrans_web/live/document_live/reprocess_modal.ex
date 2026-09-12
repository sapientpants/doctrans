defmodule DoctransWeb.DocumentLive.ReprocessModal do
  @moduledoc "State transitions and function component for page reprocessing."
  use DoctransWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Doctrans.Config
  alias Doctrans.Processing.{DocumentReprocessing, OpenAI}
  alias DoctransWeb.ErrorMessages

  @doc "Initializes model selections and modal state."
  def init(socket) do
    socket
    |> assign(:show_reprocess_modal, false)
    |> assign(:reprocess_scope, :page)
    |> assign(:available_models, [])
    |> assign(:models_loading, false)
    |> assign(:model_fetch_error, nil)
    |> assign(:extraction_model, Config.OpenAI.vision_model())
    |> assign(:translation_model, Config.OpenAI.translation_model())
    |> assign_form()
  end

  # Show reprocess button when page has completed processing or has an error
  # but not when it's currently processing (to prevent double-processing)
  def can_reprocess?(nil), do: false

  def can_reprocess?(page) do
    page.extraction_status in ["completed", "error"] &&
      page.translation_status in ["completed", "error", "pending"]
  end

  def handle_event("show_document_reprocess_modal", params, socket) do
    handle_event("show_reprocess_modal", params, assign(socket, :reprocess_scope, :document))
  end

  def handle_event("show_reprocess_modal", _params, socket) do
    # Show modal and trigger async model fetch
    socket =
      socket
      |> select_page_models()
      |> assign(:show_reprocess_modal, true)
      |> assign(:models_loading, true)

    send(self(), :fetch_available_models)

    {:noreply, socket}
  end

  def handle_event("hide_reprocess_modal", _params, socket) do
    {:noreply, socket |> assign(:show_reprocess_modal, false) |> assign(:reprocess_scope, :page)}
  end

  def handle_event("update_reprocess_models", params, socket) do
    socket =
      socket
      |> assign(:extraction_model, params["extraction_model"] || socket.assigns.extraction_model)
      |> assign(
        :translation_model,
        params["translation_model"] || socket.assigns.translation_model
      )
      |> assign_form()

    {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ["reprocess_page", "reprocess_document"] do
    scope = if event == "reprocess_document", do: :document, else: :page

    opts = [
      extraction_model: params["extraction_model"],
      translation_model: params["translation_model"]
    ]

    result =
      if requested_scope?(socket, scope) and known_models?(socket, opts),
        do: submit(socket, scope, opts),
        else: {:error, :invalid_model}

    {:noreply, apply_reprocess_result(socket, scope, result)}
  end

  defp requested_scope?(socket, scope), do: scope == socket.assigns.reprocess_scope

  defp known_models?(socket, opts) do
    models = socket.assigns.available_models
    opts[:extraction_model] in models and opts[:translation_model] in models
  end

  defp apply_reprocess_result(socket, scope, {:ok, result}) do
    socket = if scope == :page, do: assign(socket, :current_page, result), else: socket

    message =
      if scope == :document,
        do: gettext("Document queued for reprocessing"),
        else: gettext("Page queued for reprocessing")

    socket |> close_reprocess_modal() |> put_flash(:info, message)
  end

  defp apply_reprocess_result(socket, _scope, {:error, reason}) do
    socket |> close_reprocess_modal() |> put_flash(:error, ErrorMessages.message(reason))
  end

  defp close_reprocess_modal(socket) do
    socket
    |> assign(:show_reprocess_modal, false)
    |> assign(:reprocess_scope, :page)
  end

  defp submit(socket, :document, opts),
    do:
      DocumentReprocessing.reprocess_document(
        socket.assigns.document.id,
        Keyword.put(opts, :expected_run_id, socket.assigns.document.processing_run_id)
      )

  defp submit(%{assigns: %{current_page: nil}}, :page, _opts), do: {:error, :page_not_found}

  defp submit(socket, :page, opts),
    do: DocumentReprocessing.reprocess_page(socket.assigns.current_page.id, opts)

  def fetch_available_models(socket) do
    {models, error} =
      case OpenAI.list_models() do
        {:ok, models} -> {Enum.reject(models, &embedding_model?/1), nil}
        {:error, _} -> {[], ErrorMessages.message(:models_unavailable)}
      end

    socket =
      socket
      |> assign(:available_models, models)
      |> assign(:models_loading, false)
      |> assign(:model_fetch_error, error)
      |> assign(:extraction_model, available_selection(socket.assigns.extraction_model, models))
      |> assign(:translation_model, available_selection(socket.assigns.translation_model, models))
      |> assign_form()

    {:noreply, socket}
  end

  defp select_page_models(
         %{assigns: %{reprocess_scope: :page, current_page: %{} = page}} = socket
       ) do
    socket
    |> assign(:extraction_model, page.extraction_model || Config.OpenAI.vision_model())
    |> assign(:translation_model, page.translation_model || Config.OpenAI.translation_model())
    |> assign_form()
  end

  defp select_page_models(socket), do: socket

  defp available_selection(model, models), do: if(model in models, do: model, else: "")

  defp embedding_model?(model) do
    model == Config.get(:embedding, :model) ||
      String.contains?(String.downcase(model), "embed")
  end

  defp assign_form(socket) do
    assign(
      socket,
      :reprocess_form,
      to_form(%{
        "extraction_model" => socket.assigns.extraction_model,
        "translation_model" => socket.assigns.translation_model
      })
    )
  end

  attr :page, :map, required: true
  attr :document, :map, default: nil
  attr :scope, :atom, default: :page
  attr :form, Phoenix.HTML.Form, required: true
  attr :available_models, :list, required: true
  attr :models_loading, :boolean, default: false
  attr :model_fetch_error, :string, default: nil

  def reprocess_modal(assigns) do
    options =
      if assigns.models_loading,
        do: [{gettext("Loading models..."), ""}],
        else: [{gettext("Select a model"), ""} | Enum.sort(assigns.available_models)]

    assigns = assign(assigns, :model_options, options)

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      id="reprocess-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="reprocess-title"
      phx-window-keydown="hide_reprocess_modal"
      phx-key="escape"
      phx-mounted={JS.push_focus() |> JS.focus_first(to: "#reprocess-modal")}
      phx-remove={JS.pop_focus()}
    >
      <div class="relative z-10 w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl">
        <button
          type="button"
          phx-click="hide_reprocess_modal"
          class="absolute right-3 top-3 rounded-lg p-2 transition-colors hover:bg-base-200"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>

        <h3 id="reprocess-title" class="font-bold text-lg mb-4">
          {if @scope == :document, do: gettext("Reprocess document"), else: gettext("Reprocess Page")}
        </h3>
        <p :if={@scope == :document} class="mb-3 font-medium">{@document.title}</p>
        <p class="text-sm text-base-content/70 mb-4">
          {if @scope == :document,
            do:
              gettext(
                "Run every processing step again from the original upload. Existing pages and search results will be replaced. This may take some time."
              ),
            else: gettext("Select models to use for re-extracting and re-translating this page.")}
        </p>

        <div :if={@model_fetch_error} id="reprocess-model-error" class="alert alert-error mb-4">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{@model_fetch_error}</span>
        </div>

        <.form
          for={@form}
          phx-submit={if @scope == :document, do: "reprocess_document", else: "reprocess_page"}
          phx-change="update_reprocess_models"
          id={if @scope == :document, do: "document-reprocess-form", else: "reprocess-form"}
        >
          <.input
            field={@form[:extraction_model]}
            type="select"
            label={gettext("Extraction Model")}
            options={@model_options}
            class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-base-content focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20 disabled:opacity-50"
            id="extraction-model-select"
            disabled={@models_loading}
          />
          <.input
            field={@form[:translation_model]}
            type="select"
            label={gettext("Translation Model")}
            options={@model_options}
            class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-base-content focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20 disabled:opacity-50"
            id="translation-model-select"
            disabled={@models_loading}
          />

          <div class="mt-6 flex justify-end gap-3">
            <button
              type="button"
              id="reprocess-cancel"
              phx-click="hide_reprocess_modal"
              class="btn-ghost rounded-lg px-4 py-2 transition-colors hover:bg-base-200"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="rounded-lg bg-primary px-4 py-2 font-medium text-primary-content transition-opacity hover:opacity-90 disabled:opacity-50"
              disabled={
                @models_loading || @form[:extraction_model].value not in @available_models ||
                  @form[:translation_model].value not in @available_models
              }
              id={
                if @scope == :document, do: "document-reprocess-submit", else: "reprocess-submit-btn"
              }
              phx-disable-with={gettext("Queuing…")}
            >
              {gettext("Reprocess")}
            </button>
          </div>
        </.form>
      </div>
      <button
        type="button"
        tabindex="-1"
        aria-label={gettext("Cancel")}
        class="absolute inset-0"
        phx-click="hide_reprocess_modal"
      >
      </button>
    </div>
    """
  end
end
