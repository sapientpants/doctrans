defmodule DoctransWeb.DocumentLive.Components do
  @moduledoc """
  Shared UI components for document LiveViews.
  """
  use DoctransWeb, :html

  alias DoctransWeb.ErrorMessages

  @doc """
  Renders a document card for the dashboard grid.
  """
  attr :summary, Doctrans.Documents.Summary, required: true

  def document_card(assigns) do
    assigns =
      assigns
      |> assign(:document, assigns.summary.document)
      |> assign(:progress, assigns.summary.progress)
      |> assign(:status_color, status_color(assigns.summary.document.status))
      |> assign(:status_text, status_text(assigns.summary.document.status))

    ~H"""
    <div class="card bg-base-200 shadow-lg hover:shadow-xl transition-shadow">
      <%!-- The thumbnail is the only content, and when a document has no extracted
            first page that content is a decorative icon with no text of its own. The
            link would otherwise be announced as an unnamed destination. --%>
      <.link
        navigate={~p"/documents/#{@document.id}"}
        class="block"
        aria-label={gettext("Open %{title}", title: @document.title)}
      >
        <figure class="px-4 pt-4">
          <div class="aspect-[3/4] bg-base-300 rounded-lg flex items-center justify-center overflow-hidden">
            <.document_thumbnail document={@document} image_path={@summary.thumbnail_path} />
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
            {ngettext("%{count} page", "%{count} pages", @document.total_pages,
              count: @document.total_pages
            )}
          </span>
        </div>
        <.processing_progress
          :if={@progress < 100}
          id={"document-progress-#{@document.id}"}
          document={@document}
          progress={@progress}
          failed_pages={@summary.failed_pages}
        />
        <div class="card-actions justify-end mt-2">
          <button
            type="button"
            phx-click="delete_document"
            phx-value-id={@document.id}
            data-confirm={
              gettext("Are you sure you want to delete this document? This cannot be undone.")
            }
            class="btn btn-ghost btn-xs text-error"
            aria-label={gettext("Delete %{title}", title: @document.title)}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :document, :map, required: true
  attr :progress, :float, required: true
  attr :failed_pages, :list, default: []

  def processing_progress(assigns) do
    ~H"""
    <div
      :if={@document.status in ~w(queued extracting processing completed error)}
      id={@id}
      class="my-2 space-y-2"
    >
      <div class="flex items-center justify-between gap-4 text-xs text-base-content/70">
        <span>{status_text(@document.status)}</span>
        <span :if={@document.total_pages}>{Float.round(@progress, 1)}%</span>
        <span :if={!@document.total_pages}>{gettext("Preparing pages…")}</span>
      </div>
      <progress
        aria-label={gettext("Processing progress")}
        class="block h-2 w-full overflow-hidden rounded-full accent-primary"
        value={if @document.total_pages || @document.status == "queued", do: @progress, else: nil}
        max="100"
      />
      <p
        :if={@document.status == "error"}
        id={"#{@id}-failure"}
        data-failed-pages={Enum.join(@failed_pages, ",")}
        class="text-xs text-error"
      >
        {if @failed_pages == [],
          do:
            gettext("Processing failed. You can reprocess the document when its jobs have finished."),
          else: ErrorMessages.message({:pages_failed, [page_numbers: Enum.join(@failed_pages, ", ")]})}
      </p>
    </div>
    """
  end

  @doc """
  Renders a document thumbnail from its first page.

  The thumbnail is shown when the first page has been extracted and its
  record exists in the database. This ensures we don't show a broken image
  during the period between total_pages being set and page 1 being extracted.
  """
  attr :document, :map, required: true

  attr :image_path, :string, default: nil

  def document_thumbnail(assigns) do
    ~H"""
    <%!-- `alt` is empty on purpose: the card's heading and the link's own label already
          carry the title, so announcing the image repeats what was just read. --%>
    <img
      :if={@image_path}
      src={"/uploads/#{@image_path}"}
      alt=""
      class="w-full h-full object-cover"
    />
    <.icon
      :if={!@image_path}
      name="hero-document-text"
      class="w-16 h-16 text-base-content/30"
    />
    """
  end

  @doc """
  Returns the badge color class for a document status.
  """
  def status_color("uploading"), do: "badge-info"
  def status_color("extracting"), do: "badge-info"
  def status_color("queued"), do: "badge-info"
  def status_color("processing"), do: "badge-warning"
  def status_color("completed"), do: "badge-success"
  def status_color("error"), do: "badge-error"
  def status_color(_), do: "badge-ghost"

  @doc """
  Returns the display text for a document status.
  """
  def status_text("uploading"), do: gettext("Uploading")
  def status_text("extracting"), do: gettext("Processing")
  def status_text("queued"), do: gettext("Queued")
  def status_text("processing"), do: gettext("Processing")
  def status_text("completed"), do: gettext("Completed")
  def status_text("error"), do: gettext("Error")
  def status_text(_), do: gettext("Unknown")

  @doc """
  Returns the sort label for the sort dropdown.
  """
  def sort_label(:inserted_at, :desc), do: gettext("Newest")
  def sort_label(:inserted_at, :asc), do: gettext("Oldest")
  def sort_label(:title, :asc), do: gettext("A-Z")
  def sort_label(:title, :desc), do: gettext("Z-A")
  def sort_label(_, _), do: gettext("Sort")

  @doc """
  Returns the display name for a language code.
  """
  def language_name("da"), do: gettext("Danish")
  def language_name("de"), do: gettext("German")
  def language_name("en"), do: gettext("English")
  def language_name("es"), do: gettext("Spanish")
  def language_name("fr"), do: gettext("French")
  def language_name("it"), do: gettext("Italian")
  def language_name("nl"), do: gettext("Dutch")
  def language_name("no"), do: gettext("Norwegian")
  def language_name("pl"), do: gettext("Polish")
  def language_name("pt"), do: gettext("Portuguese")
  def language_name("sv"), do: gettext("Swedish")
  def language_name(code), do: code

  @doc """
  Returns the translation direction of a document, as "Source → Target".

  A document whose source language has not been identified yet -- one uploaded
  with the picker left on "Detect automatically", before processing resolves it
  -- has no left-hand side to name, so it reads as the target language alone:
  exactly what the header showed before either side was recorded.

  The arrow is punctuation rather than a translatable message: it reads the same
  in every locale this interface is offered in, and the two names either side of
  it are already translated by `language_name/1`.
  """
  def language_direction(%{source_language: nil} = document) do
    language_name(document.target_language)
  end

  def language_direction(document) do
    "#{language_name(document.source_language)} → #{language_name(document.target_language)}"
  end
end
