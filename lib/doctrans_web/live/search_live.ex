defmodule DoctransWeb.SearchLive do
  @moduledoc """
  Search results page for finding content across all documents.
  """
  use DoctransWeb, :live_view

  alias Doctrans.Search

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:query, "")
      |> assign(:results, [])
      |> assign(:searching, false)
      |> assign(:searched, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"q" => query}, _uri, socket) when query != "" do
    socket =
      socket
      |> assign(:query, query)
      |> assign(:searching, true)

    # Perform the search
    case Search.search(query) do
      {:ok, results} ->
        {:noreply, assign(socket, results: results, searching: false, searched: true)}

      {:error, _reason} ->
        {:noreply, assign(socket, results: [], searching: false, searched: true)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="w-full px-6 py-8">
        <div class="flex items-center gap-4 mb-8">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">{gettext("Search")}</h1>
            <p class="text-base-content/70 text-sm">{gettext("Find content across all documents")}</p>
          </div>
        </div>

        <form phx-submit="search" class="mb-8" id="search-form">
          <div class="relative max-w-xl">
            <.icon
              name="hero-magnifying-glass"
              class="w-5 h-5 absolute left-4 top-1/2 -translate-y-1/2 z-10 text-base-content/60 pointer-events-none"
            />
            <input
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search...")}
              autofocus
              class={[
                "input input-bordered w-full pl-12 pr-4",
                "focus:border-primary/50 transition-colors"
              ]}
              id="search-input"
            />
          </div>
        </form>

        <div :if={@searching} class="flex items-center gap-2 py-8 text-base-content/60">
          <span class="loading loading-spinner loading-md"></span>
          <span>{gettext("Searching...")}</span>
        </div>

        <div :if={!@searching && @searched && @results != []}>
          <p class="text-sm text-base-content/50 mb-4">
            {ngettext(
              "%{count} result for \"%{query}\"",
              "%{count} results for \"%{query}\"",
              length(@results),
              count: length(@results),
              query: @query
            )}
          </p>
          <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3">
            <.link
              :for={result <- @results}
              navigate={
                ~p"/documents/#{result.document_id}?page=#{result.page_number}&from=search&q=#{@query}"
              }
              class="group block rounded-lg bg-base-200/50 hover:bg-base-200 transition-colors overflow-hidden"
            >
              <div class="aspect-[3/4] bg-base-300 relative flex items-center justify-center">
                <img
                  :if={result.image_path}
                  src={"/uploads/#{result.image_path}"}
                  alt={"Page #{result.page_number}"}
                  class="max-w-full max-h-full object-contain"
                />
                <div
                  :if={!result.image_path}
                  class="w-full h-full flex items-center justify-center"
                >
                  <.icon name="hero-document-text" class="w-12 h-12 text-base-content/30" />
                </div>
                <div class="absolute bottom-2 right-2 px-2 py-1 bg-base-100/90 rounded text-xs font-medium">
                  {gettext("Page %{number}", number: result.page_number)}
                </div>
              </div>
              <div class="p-3">
                <h3 class="font-medium text-sm truncate group-hover:text-primary transition-colors">
                  {result.document_title}
                </h3>
              </div>
            </.link>
          </div>
        </div>

        <div :if={!@searching && @searched && @results == []} class="text-center py-16">
          <.icon name="hero-magnifying-glass" class="w-16 h-16 mx-auto text-base-content/20" />
          <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("No results found")}</h3>
          <p class="mt-2 text-base-content/70">{gettext("Try a different search term.")}</p>
        </div>

        <div :if={!@searching && !@searched} class="text-center py-16">
          <.icon name="hero-magnifying-glass" class="w-16 h-16 mx-auto text-base-content/20" />
          <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("Search documents")}</h3>
          <p class="mt-2 text-base-content/70">
            {gettext("Enter a search term to find content across all your documents.")}
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}
    end
  end
end
