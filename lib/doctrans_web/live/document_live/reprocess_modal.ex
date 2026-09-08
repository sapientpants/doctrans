defmodule DoctransWeb.DocumentLive.ReprocessModal do
  @moduledoc "State transitions and function component for page reprocessing."
  use DoctransWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Doctrans.{Config, Documents}
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.{OpenAI, Worker}

  @doc "Initializes model selections and modal state."
  def init(socket) do
    socket
    |> assign(:show_reprocess_modal, false)
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
    page.extraction_status in ["completed", "error"] ||
      page.translation_status == "error"
  end

  def handle_event("show_reprocess_modal", _params, socket) do
    # Show modal and trigger async model fetch
    socket =
      socket
      |> assign(:show_reprocess_modal, true)
      |> assign(:models_loading, true)

    send(self(), :fetch_available_models)

    {:noreply, socket}
  end

  def handle_event("hide_reprocess_modal", _params, socket) do
    {:noreply, assign(socket, :show_reprocess_modal, false)}
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

  def handle_event("reprocess_page", params, socket) do
    page = socket.assigns.current_page
    extraction_model = params["extraction_model"]
    translation_model = params["translation_model"]
    available_models = socket.assigns.available_models

    # Validate model selection
    if extraction_model not in available_models or translation_model not in available_models do
      socket =
        socket
        |> put_flash(:error, gettext("Invalid model selection"))
        |> assign(:show_reprocess_modal, false)

      {:noreply, socket}
    else
      case Documents.reset_page_for_reprocessing(page) do
        {:ok, page} ->
          _ = Topics.broadcast_page_update(page)

          _ =
            Worker.queue_page_reprocess(page.id,
              extraction_model: extraction_model,
              translation_model: translation_model
            )

          socket =
            socket
            |> assign(:current_page, page)
            |> assign(:show_reprocess_modal, false)
            |> put_flash(:info, gettext("Page queued for reprocessing"))

          {:noreply, socket}

        {:error, _reason} ->
          socket =
            socket
            |> put_flash(:error, gettext("Failed to reset page for reprocessing"))
            |> assign(:show_reprocess_modal, false)

          {:noreply, socket}
      end
    end
  end

  def fetch_available_models(socket) do
    {models, error} =
      case OpenAI.list_models() do
        {:ok, models} -> {models, nil}
        {:error, _} -> {[], gettext("Failed to fetch models from OpenAI")}
      end

    socket =
      socket
      |> assign(:available_models, models)
      |> assign(:models_loading, false)
      |> assign(:model_fetch_error, error)

    {:noreply, socket}
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
  attr :form, Phoenix.HTML.Form, required: true
  attr :available_models, :list, required: true
  attr :models_loading, :boolean, default: false
  attr :model_fetch_error, :string, default: nil

  def reprocess_modal(assigns) do
    options =
      if assigns.models_loading,
        do: [{gettext("Loading models..."), ""}],
        else: Enum.sort(assigns.available_models)

    assigns = assign(assigns, :model_options, options)

    ~H"""
    <div class="modal modal-open" id="reprocess-modal">
      <div class="modal-box max-w-md">
        <button
          type="button"
          phx-click="hide_reprocess_modal"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>

        <h3 class="font-bold text-lg mb-4">{gettext("Reprocess Page")}</h3>
        <p class="text-sm text-base-content/70 mb-4">
          {gettext("Select models to use for re-extracting and re-translating this page.")}
        </p>

        <div :if={@model_fetch_error} id="reprocess-model-error" class="alert alert-error mb-4">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{@model_fetch_error}</span>
        </div>

        <.form
          for={@form}
          phx-submit="reprocess_page"
          phx-change="update_reprocess_models"
          id="reprocess-form"
        >
          <.input
            field={@form[:extraction_model]}
            type="select"
            label={gettext("Extraction Model")}
            options={@model_options}
            class="select select-bordered w-full"
            id="extraction-model-select"
            disabled={@models_loading}
          />
          <.input
            field={@form[:translation_model]}
            type="select"
            label={gettext("Translation Model")}
            options={@model_options}
            class="select select-bordered w-full"
            id="translation-model-select"
            disabled={@models_loading}
          />

          <div class="modal-action">
            <button
              type="button"
              id="reprocess-cancel"
              phx-click="hide_reprocess_modal"
              class="btn btn-ghost"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@models_loading || @available_models == []}
              id="reprocess-submit-btn"
            >
              {gettext("Reprocess")}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="hide_reprocess_modal"></div>
    </div>
    """
  end
end
