defmodule DoctransWeb.CoreComponents do
  @moduledoc """
  Core UI components built on Tailwind CSS and daisyUI.

  For form inputs, see `DoctransWeb.FormComponents`.
  """
  use Phoenix.Component
  use Gettext, backend: DoctransWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
      <.flash kind={:error} transient={false}>Connection lost</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"

  attr :transient, :boolean,
    default: true,
    doc:
      "whether the notice dismisses itself on a timer; `false` for banners driven by " <>
        "`phx-connected`/`phx-disconnected`, which need the node to survive"

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      |> assign(:flash_msg, Phoenix.Flash.get(assigns.flash, assigns.kind))

    # Only a notice whose text *came from* the flash map may clear it. Keying off
    # `@flash_msg` alone would let a notice rendering its inner block discard an
    # unrelated message of the same kind that the user never saw.
    assigns =
      assign(assigns, :from_flash?, assigns.inner_block == [] and assigns.flash_msg != nil)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || @flash_msg}
      id={@id}
      phx-click={
        if @from_flash? do
          JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")
        else
          hide("##{@id}")
        end
      }
      phx-hook={@transient && "AutoDismiss"}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("Close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :string
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a modal dialog.

  Owns the parts that every dialog has to get right and that are easy to get
  subtly different when each one spells them out for itself: the container
  semantics, a named close button, a click-to-dismiss backdrop, and the focus
  contract implemented by the `DialogFocus` hook -- focus moves inside on open,
  Tab cycles within, and focus returns to `return_focus` when it closes, or to
  the page's `<main>` if the patch that closed the dialog also removed or
  disabled that trigger. Escape pushes `on_close`, as do the close button and
  the backdrop.

  Only layout classes differ between call sites, so those are the attributes;
  the semantics are not overridable.

  ## Examples

      <.dialog
        id="upload-modal"
        title_id="upload-modal-title"
        on_close="hide_upload_modal"
        return_focus="#upload-document-btn"
        class="modal modal-open"
        box_class="modal-box max-w-lg"
        backdrop_class="modal-backdrop bg-black/50"
      >
        <h3 id="upload-modal-title">Upload New Document</h3>
      </.dialog>
  """
  attr :id, :string, required: true

  attr :title_id, :string,
    required: true,
    doc: "id of the element that names the dialog, referenced by aria-labelledby"

  attr :on_close, :string,
    required: true,
    doc: "event pushed by Escape, the close button and the backdrop"

  attr :return_focus, :string,
    required: true,
    doc: "selector for the control that opened the dialog, focused again on close"

  attr :class, :string, default: nil, doc: "classes for the dialog container"
  attr :box_class, :string, default: nil, doc: "classes for the content box"
  attr :backdrop_class, :string, default: nil, doc: "classes for the backdrop"
  attr :close_class, :string, default: nil, doc: "classes for the close button"

  slot :inner_block, required: true

  def dialog(assigns) do
    ~H"""
    <div
      id={@id}
      class={@class}
      role="dialog"
      aria-modal="true"
      aria-labelledby={@title_id}
      phx-window-keydown={@on_close}
      phx-key="escape"
      phx-hook="DialogFocus"
      data-return-focus={@return_focus}
    >
      <div class={@box_class}>
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click={@on_close}
          aria-label={gettext("Close")}
          class={@close_class}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
        {render_slot(@inner_block)}
      </div>
      <%!-- A button rather than a div so dismissing by click is a real control
            with real click semantics. `tabindex="-1"` keeps it out of the tab
            cycle and `aria-hidden` keeps it off the virtual cursor: it only
            duplicates Cancel, which is already in both. --%>
      <button
        type="button"
        tabindex="-1"
        aria-hidden="true"
        class={@backdrop_class}
        phx-click={@on_close}
      >
      </button>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />

  Icons are always `aria-hidden`: they are CSS masks with no text, so they never
  carried an accessible name to begin with. A control whose only content is an
  icon must therefore carry its own `aria-label`.
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(DoctransWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(DoctransWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
