defmodule DoctransWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DoctransWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class="min-h-screen">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.connectivity_notice
        id="client-error"
        error_class="phx-client-error"
        title={gettext("We can't find the internet")}
      />

      <.connectivity_notice
        id="server-error"
        error_class="phx-server-error"
        title={gettext("Something went wrong!")}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true

  attr :error_class, :string,
    required: true,
    doc: "the LiveView body class that marks this kind of disconnection"

  # Rendered with `transient={false}` so the auto-dismiss hook never takes the node
  # out: `phx-disconnected` looks the element up by id, long after mount.
  defp connectivity_notice(assigns) do
    ~H"""
    <.flash
      id={@id}
      kind={:error}
      title={@title}
      transient={false}
      phx-disconnected={show(".#{@error_class} ##{@id}") |> JS.remove_attribute("hidden")}
      phx-connected={hide("##{@id}") |> JS.set_attribute({"hidden", ""})}
      hidden
    >
      {gettext("Attempting to reconnect")}
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
    </.flash>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        type="button"
        aria-label={gettext("Use system theme")}
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        aria-label={gettext("Use light theme")}
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        aria-label={gettext("Use dark theme")}
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
