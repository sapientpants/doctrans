defmodule DoctransWeb.SearchLive do
  @moduledoc """
  Search results page for finding content across all documents.
  """
  use DoctransWeb, :live_view

  alias Doctrans.Search

  require Logger

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:query, "")
      |> assign(:results, [])
      |> assign(:searching, false)
      |> assign(:searched, false)
      |> assign(:search_error, false)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:total_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"q" => query} = params, _uri, socket) when query != "" do
    page = parse_page(params["page"])
    offset = (page - 1) * @per_page

    socket =
      socket
      |> assign(:query, query)
      |> assign(:page, page)
      |> assign(:searching, true)
      |> assign(:search_error, false)

    # Get total count and search results
    with {:ok, total_count} <- Search.count_results(query),
         {:ok, results} <- Search.search(query, limit: @per_page, offset: offset) do
      {:noreply,
       assign(socket,
         results: results,
         total_count: total_count,
         searching: false,
         searched: true
       )}
    else
      {:error, reason} ->
        Logger.warning("Search failed: #{inspect(reason)}")

        socket =
          socket
          |> assign(
            results: [],
            total_count: 0,
            searching: false,
            searched: true,
            search_error: true
          )
          |> put_flash(:error, gettext("Search is temporarily unavailable. Please try again."))

        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp parse_page(nil), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {p, ""} when p > 0 -> p
      _ -> 1
    end
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
            {pagination_text(@total_count, @page, @per_page, @query)}
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
                <div class="absolute top-2 left-2 px-2 py-1 bg-base-100/90 rounded text-xs font-mono text-base-content/70">
                  {:erlang.float_to_binary(result.score, decimals: 3)}
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
          <.pagination
            :if={@total_count > @per_page}
            page={@page}
            total_count={@total_count}
            per_page={@per_page}
            query={@query}
          />
        </div>

        <div
          :if={!@searching && @searched && @results == [] && !@search_error}
          class="text-center py-16"
        >
          <.icon name="hero-magnifying-glass" class="w-16 h-16 mx-auto text-base-content/20" />
          <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("No results found")}</h3>
          <p class="mt-2 text-base-content/70">{gettext("Try a different search term.")}</p>
        </div>

        <div :if={!@searching && @search_error} class="text-center py-16">
          <.icon name="hero-exclamation-triangle" class="w-16 h-16 mx-auto text-warning" />
          <h3 class="mt-4 text-lg font-medium text-base-content">
            {gettext("Search unavailable")}
          </h3>
          <p class="mt-2 text-base-content/70">
            {gettext("Please try again in a moment.")}
          </p>
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

  defp pagination_text(total_count, page, per_page, query) do
    start_idx = (page - 1) * per_page + 1
    end_idx = min(page * per_page, total_count)

    gettext("Showing %{start}-%{end} of %{total} results for \"%{query}\"",
      start: start_idx,
      end: end_idx,
      total: total_count,
      query: query
    )
  end

  defp pagination(assigns) do
    total_pages = ceil(assigns.total_count / assigns.per_page)
    assigns = assign(assigns, :total_pages, total_pages)

    ~H"""
    <div class="flex justify-center items-center gap-2 mt-6">
      <.link
        :if={@page > 1}
        patch={~p"/search?q=#{@query}&page=#{@page - 1}"}
        class="btn btn-sm"
      >
        <.icon name="hero-chevron-left" class="w-4 h-4" />
        {gettext("Previous")}
      </.link>
      <span class="text-sm text-base-content/70">
        {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
      </span>
      <.link
        :if={@page < @total_pages}
        patch={~p"/search?q=#{@query}&page=#{@page + 1}"}
        class="btn btn-sm"
      >
        {gettext("Next")}
        <.icon name="hero-chevron-right" class="w-4 h-4" />
      </.link>
    </div>
    """
  end
end
