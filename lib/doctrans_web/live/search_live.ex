defmodule DoctransWeb.SearchLive do
  @moduledoc """
  Search results page for finding content across all documents.
  """
  use DoctransWeb, :live_view

  alias Doctrans.Search
  alias Doctrans.Validation
  alias DoctransWeb.ErrorMessages

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
      |> assign(:retrieval, :hybrid)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:total_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"q" => query} = params, _uri, socket) when query != "" do
    case Validation.validate_search_query(query) do
      {:ok, validated_query} ->
        {:noreply, run_search(socket, validated_query, parse_page(params["page"]))}

      {:error, reason} ->
        {:noreply, reject_query(socket, query, reason)}
    end
  end

  # A query-less URL -- browser Back, say -- has no result to wait for. Clearing
  # `:query` alongside the results is what makes the staleness guard below cover
  # this path: a validated query is never empty, so an in-flight search can no
  # longer match the view's state and render itself under a URL without a `q`.
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> cancel_async(:search) |> clear_search()}
  end

  # The payload names the query and page the search was started for. LiveView
  # drops the result of a task a later `start_async` superseded, but a search
  # cancelled without a replacement can still report in the moment before its
  # exit signal lands: `cancel_async/2` kills the task without clearing the ref
  # it is tracked under, so LiveView has nothing to prune that result against.
  # Both such callers -- `reject_query/3` and the query-less `handle_params/3`
  # -- overwrite `:query`, so comparing against it rejects the late result.
  @impl true
  def handle_async(:search, {:ok, {query, page, result}}, socket) do
    if current_search?(socket, query, page) do
      {:noreply, apply_search_result(socket, result)}
    else
      {:noreply, socket}
    end
  end

  # A search we cancelled ourselves is not a failure, and must not raise the
  # error panel. Reached from the two callers that cancel without starting a
  # replacement -- `reject_query/3` and the query-less `handle_params/3`;
  # a superseded search is pruned by LiveView before this callback runs.
  def handle_async(:search, {:exit, {:shutdown, :cancel}}, socket) do
    {:noreply, socket}
  end

  def handle_async(:search, {:exit, reason}, socket) do
    {:noreply, search_failed(socket, reason)}
  end

  defp current_search?(socket, query, page) do
    socket.assigns.query == query and socket.assigns.page == page
  end

  # `:retrieval` says how this page of results was found: `:keyword_only` means
  # the query could not be embedded, so full-text matches are all there is and
  # the page may be missing what only semantic search would have found. It is a
  # property of the result, so it is assigned with it and never survives it.
  defp apply_search_result(
         socket,
         {:ok, %{results: results, total_count: total_count, retrieval: retrieval}}
       ) do
    assign(socket,
      results: results,
      total_count: total_count,
      retrieval: retrieval,
      searching: false,
      searched: true,
      search_error: false
    )
  end

  defp apply_search_result(socket, {:error, reason}), do: search_failed(socket, reason)

  defp run_search(socket, query, page) do
    socket =
      socket
      |> assign(:query, query)
      |> assign(:page, page)
      |> assign(:searching, true)
      |> assign(:search_error, false)
      |> assign(:retrieval, :hybrid)

    if connected?(socket) do
      offset = max(0, (page - 1) * @per_page)

      # Cancelling first stops a superseded query from burning an inference call,
      # and LiveView ignores the result of an earlier task once a later
      # `start_async` reuses the name, so an older response can never replace a
      # newer one (see `Phoenix.LiveView.start_async/3`).
      socket
      |> cancel_async(:search)
      |> start_async(
        :search,
        fn ->
          {query, page, Search.search_with_count(query, limit: @per_page, offset: offset)}
        end,
        supervisor: Doctrans.TaskSupervisor
      )
    else
      # The disconnected mount only renders the loading state; the query is
      # embedded once, by the connected mount.
      socket
    end
  end

  defp search_failed(socket, reason) do
    # Bounded: an exit reason carries a stacktrace whose frames can hold the
    # query embedding -- 1024 floats -- and the raw query text.
    Logger.warning("Search failed: #{inspect(reason, limit: 10, printable_limit: 256)}")

    socket
    |> assign(
      results: [],
      total_count: 0,
      retrieval: :hybrid,
      searching: false,
      searched: true,
      search_error: true
    )
    |> put_flash(:error, ErrorMessages.message(:search_failed))
  end

  defp reject_query(socket, query, reason) do
    socket
    |> cancel_async(:search)
    |> clear_search()
    |> assign(:query, query)
    |> assign(:searched, true)
    |> put_flash(:error, ErrorMessages.message(reason))
  end

  defp clear_search(socket) do
    socket
    |> assign(:query, "")
    |> assign(:page, 1)
    |> assign(:results, [])
    |> assign(:total_count, 0)
    |> assign(:retrieval, :hybrid)
    |> assign(:searching, false)
    |> assign(:searched, false)
    |> assign(:search_error, false)
  end

  defp parse_page(nil), do: 1

  # Clamped, because `page` reaches Postgres as an OFFSET: an unbounded one
  # overflows bigint and fails the query instead of returning the empty page the
  # user actually asked for. The bound is far past any real corpus, so clamping
  # only ever rewrites a page number that had no results behind it.
  @max_page 100_000

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {p, ""} when p > 0 -> min(p, @max_page)
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

        <div
          :if={@searching}
          id="search-loading"
          class="flex items-center gap-2 py-8 text-base-content/60"
        >
          <span class="loading loading-spinner loading-md"></span>
          <span>{gettext("Searching...")}</span>
        </div>

        <%!-- One bar above both outcomes: a keyword-only search that matched
        nothing is exactly the case a reader would otherwise read as "nothing in
        my library matches", so it needs the notice as much as a page of hits
        does. Rendering it once keeps the id unique whichever outcome shows. --%>
        <div
          :if={!@searching && @searched && !@search_error && @retrieval == :keyword_only}
          id="search-degraded"
          role="status"
          class="flex items-start gap-3 max-w-3xl mb-6 px-4 py-3 rounded-lg border border-warning/30 bg-warning/10"
        >
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0 text-warning" />
          <div class="text-sm">
            <p class="font-medium text-base-content">
              {gettext("Semantic search is unavailable, so only keyword matches are shown.")}
            </p>
            <p class="text-base-content/70">
              {gettext("These results may be incomplete until it is back.")}
            </p>
          </div>
        </div>

        <div :if={!@searching && @searched && @results != []} id="search-results">
          <p id="search-summary" class="text-sm text-base-content/50 mb-4">
            {pagination_text(@total_count, @page, @per_page, @query)}
          </p>
          <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3">
            <.link
              :for={result <- @results}
              id={"search-result-#{result.page_id}"}
              navigate={
                ~p"/documents/#{result.document_id}?page=#{result.page_number}&from=search&q=#{@query}&search_page=#{@page}"
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
          id="search-empty"
          class="text-center py-16"
        >
          <.icon name="hero-magnifying-glass" class="w-16 h-16 mx-auto text-base-content/20" />
          <h3 class="mt-4 text-lg font-medium text-base-content">{gettext("No results found")}</h3>
          <p class="mt-2 text-base-content/70">{gettext("Try a different search term.")}</p>
        </div>

        <div :if={!@searching && @search_error} id="search-error" class="text-center py-16">
          <.icon name="hero-exclamation-triangle" class="w-16 h-16 mx-auto text-warning" />
          <h3 class="mt-4 text-lg font-medium text-base-content">
            {gettext("Search unavailable")}
          </h3>
          <p class="mt-2 text-base-content/70">
            {gettext("Please try again in a moment.")}
          </p>
        </div>

        <div :if={!@searching && !@searched} id="search-prompt" class="text-center py-16">
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
    total_pages = max(1, ceil(assigns.total_count / assigns.per_page))
    assigns = assign(assigns, :total_pages, total_pages)

    ~H"""
    <nav
      id="search-pagination"
      class="flex justify-center items-center gap-2 mt-6"
      aria-label={gettext("Search results pagination")}
    >
      <.link
        :if={@page > 1}
        patch={~p"/search?q=#{@query}&page=#{@page - 1}"}
        class="btn btn-sm"
        aria-label={gettext("Go to page %{page}", page: @page - 1)}
      >
        <.icon name="hero-chevron-left" class="w-4 h-4" />
        {gettext("Previous")}
      </.link>
      <span class="text-sm text-base-content/70" aria-live="polite">
        {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
      </span>
      <.link
        :if={@page < @total_pages}
        patch={~p"/search?q=#{@query}&page=#{@page + 1}"}
        class="btn btn-sm"
        aria-label={gettext("Go to page %{page}", page: @page + 1)}
      >
        {gettext("Next")}
        <.icon name="hero-chevron-right" class="w-4 h-4" />
      </.link>
    </nav>
    """
  end
end
