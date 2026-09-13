defmodule DoctransWeb.SearchLiveAsyncTest do
  @moduledoc """
  Covers the asynchronous search path: one embedding per submitted query, a
  loading state that renders while inference waits, a superseded query whose
  inference call is cancelled rather than left running, and the payload check
  that stops a cancelled search from reporting under the query that replaced it.

  Not async: each test swaps global `Application` env (the embedding module, or
  the stub's barrier) to observe or hold an embedding call.
  """
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Doctrans.Documents.Pages
  alias Doctrans.Search.{EmbeddingErrorStub, EmbeddingProbe}
  alias Doctrans.TestEnv
  alias DoctransWeb.SearchLive

  # A synchronous regression does not fail these tests, it wedges them: the
  # barrier is released by the very process that blocks on it. Cap the wait well
  # under ExUnit's 60s default so such a regression is reported in seconds, with
  # the barrier still on the stack, instead of stalling the suite.
  @moduletag timeout: 10_000

  # Generous, because these tests wait on a real task rather than a render.
  @async_timeout 2_000

  describe "query embeddings" do
    test "embeds a submitted query exactly once", %{conn: conn} do
      searchable_page("Contains onceonlyterm in the text", "Once Only Doc")

      TestEnv.put_env(:embedding_probe_pid, self())
      TestEnv.put_env(:embedding_module, EmbeddingProbe)

      # `live/2` runs the disconnected mount and then the connected one; only
      # the connected mount may embed.
      {:ok, view, _html} = live(conn, ~p"/search?q=onceonlyterm")
      assert render_async(view, @async_timeout) =~ "Once Only Doc"

      assert_receive {:embedded, "onceonlyterm"}, @async_timeout
      refute_receive {:embedded, "onceonlyterm"}, 100
    end
  end

  describe "loading state" do
    test "renders while the query embedding is still in flight", %{conn: conn} do
      searchable_page("Contains blockedterm in the text", "Blocked Doc")
      barrier = install_barrier("blockedterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=blockedterm")

      # The search is parked inside the embedding call, and the view says so.
      assert_receive {:embedding_started, ^barrier, task_pid}, @async_timeout
      assert has_element?(view, "#search-loading")
      refute render(view) =~ "Blocked Doc"

      send(task_pid, {:continue_embedding, barrier})

      html = render_async(view, @async_timeout)
      assert html =~ "Blocked Doc"
      refute has_element?(view, "#search-loading")
    end
  end

  describe "superseded queries" do
    test "a newer query cancels the search it replaced", %{conn: conn} do
      searchable_page("Contains staleterm in the text", "Stale Doc")
      searchable_page("Contains freshterm in the text", "Fresh Doc")

      barrier = install_barrier("staleterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=staleterm")
      assert_receive {:embedding_started, ^barrier, stale_pid}, @async_timeout

      # Monitor before the replacement is submitted. Monitoring a pid that is
      # already dead reports `:noproc`, which would say nothing about how it died.
      stale_monitor = Process.monitor(stale_pid)

      # Navigation stays responsive while the first search is parked.
      view |> element("#search-form") |> render_submit(%{q: "freshterm"})
      assert_patch(view, ~p"/search?q=freshterm")

      # The superseded search is cancelled, not merely ignored: waiting for the
      # exit, and for this exact reason, is what distinguishes abandoning its
      # inference call from letting it finish and discarding the answer.
      assert_receive {:DOWN, ^stale_monitor, :process, ^stale_pid, {:shutdown, :cancel}},
                     @async_timeout

      html = render_async(view, @async_timeout)
      assert html =~ "Fresh Doc"
      refute html =~ "Stale Doc"
    end
  end

  # `reject_query/3` cancels without starting a replacement, so its task can
  # report in the moment before the exit signal lands and LiveView has no later
  # ref to prune it against. Only the payload check stops that result, and no
  # timing-based test can reliably open that window -- so drive the callback.
  describe "handle_async/3 staleness guard" do
    test "ignores a result reported for a query the view has moved off" do
      socket = search_socket("new query", 1)
      payload = {:ok, {"old query", 1, {:ok, %{results: [result_stub()], total_count: 5}}}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.results == []
      assert socket.assigns.total_count == 0
      assert socket.assigns.searching
      refute socket.assigns.searched
    end

    test "ignores a result reported for a page the view has moved off" do
      socket = search_socket("same query", 2)
      payload = {:ok, {"same query", 1, {:ok, %{results: [result_stub()], total_count: 5}}}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.results == []
      assert socket.assigns.total_count == 0
    end

    test "applies a result reported for the current query and page" do
      result = result_stub()
      socket = search_socket("current query", 2)
      payload = {:ok, {"current query", 2, {:ok, %{results: [result], total_count: 5}}}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.results == [result]
      assert socket.assigns.total_count == 5
      refute socket.assigns.searching
      assert socket.assigns.searched
    end
  end

  # The three failure clauses below have no timing-driven route either: a
  # cancellation the view asked for is indistinguishable, from the outside, from
  # one that never happened. Drive them directly, because deleting any of them
  # is otherwise invisible to the suite.
  describe "handle_async/3 cancellation" do
    test "a cancellation the view asked for is not reported as a failure" do
      socket = search_socket("abandoned query", 1)

      assert {:noreply, socket} =
               SearchLive.handle_async(:search, {:exit, {:shutdown, :cancel}}, socket)

      # The caller that cancelled has already settled the view. Treating this as
      # a failure would raise the error panel over a query the user replaced or
      # navigated away from.
      refute socket.assigns.search_error
      assert socket.assigns.results == []
    end
  end

  describe "handle_async/3 failures" do
    test "a task that died reports the search as unavailable" do
      socket = search_socket("crashing query", 1)

      {{:noreply, socket}, log} =
        with_log(fn ->
          SearchLive.handle_async(:search, {:exit, {%RuntimeError{message: "boom"}, []}}, socket)
        end)

      assert socket.assigns.search_error
      refute socket.assigns.searching
      assert socket.assigns.searched
      assert socket.assigns.results == []
      assert log =~ "Search failed"
    end

    test "a search that returned an error reports the search as unavailable" do
      socket = search_socket("failing query", 1)
      payload = {:ok, {"failing query", 1, {:error, :timeout}}}

      {{:noreply, socket}, log} =
        with_log(fn -> SearchLive.handle_async(:search, payload, socket) end)

      assert socket.assigns.search_error
      refute socket.assigns.searching
      assert socket.assigns.searched
      assert log =~ "Search failed"
    end

    test "the failure log does not spell out the query embedding" do
      socket = search_socket("noisy query", 1)
      embedding = List.duplicate(0.123_456, 1024)
      reason = {%RuntimeError{message: "boom"}, [{Doctrans.Search, :search, [embedding], []}]}

      {_result, log} =
        with_log(fn -> SearchLive.handle_async(:search, {:exit, reason}, socket) end)

      # A stacktrace frame can carry the 1024-float query vector. Bounded
      # inspection keeps a failed search from writing a screenful of noise.
      assert log =~ "Search failed"
      refute log =~ String.duplicate("0.123456, ", 20)
    end
  end

  describe "search failures end to end" do
    test "renders the error panel when the query cannot be embedded", %{conn: conn} do
      TestEnv.put_env(:embedding_module, EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_plan, [{"unembeddableterm", :timeout}])

      {:ok, view, _html} = live(conn, ~p"/search?q=unembeddableterm")

      capture_log(fn -> render_async(view, @async_timeout) end)

      assert has_element?(view, "#search-error")
      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#search-loading")
      refute has_element?(view, "#search-empty")
    end
  end

  describe "navigating away from a search" do
    test "patching to a query-less URL clears the results behind it", %{conn: conn} do
      page = searchable_page("Contains clearedterm in the text", "Cleared Doc")

      {:ok, view, _html} = live(conn, ~p"/search?q=clearedterm")
      render_async(view, @async_timeout)
      assert has_element?(view, "#search-result-#{page.id}")

      # Browser Back onto a URL with no `q`, on the same mounted view -- which is
      # what makes this the `handle_params/3` catch-all rather than a fresh mount.
      render_patch(view, ~p"/search")

      assert has_element?(view, "#search-prompt")
      refute has_element?(view, "#search-results")
      refute has_element?(view, "#search-loading")
      refute has_element?(view, "#search-result-#{page.id}")
    end

    test "a query the view moved off cannot report under a query-less URL", %{conn: conn} do
      searchable_page("Contains abandonedterm in the text", "Abandoned Doc")
      barrier = install_barrier("abandonedterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=abandonedterm")
      assert_receive {:embedding_started, ^barrier, task_pid}, @async_timeout
      assert has_element?(view, "#search-loading")

      # Patch away while the search is parked, then let it finish. `cancel_async`
      # cannot un-send a result already in flight, so clearing `:query` is the
      # only thing standing between that result and the rendered page.
      render_patch(view, ~p"/search")
      send(task_pid, {:continue_embedding, barrier})

      refute has_element?(view, "#search-loading")
      assert has_element?(view, "#search-prompt")
      refute render(view) =~ "Abandoned Doc"
    end
  end

  defp search_socket(query, page) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        query: query,
        page: page,
        results: [],
        total_count: 0,
        searching: true,
        searched: false,
        search_error: false,
        flash: %{}
      }
    }
  end

  defp result_stub do
    %{
      page_id: Ecto.UUID.generate(),
      document_id: Ecto.UUID.generate(),
      document_title: "Result Stub Doc",
      page_number: 1,
      image_path: nil,
      score: 0.5,
      snippet: nil
    }
  end

  defp searchable_page(text, title) do
    document = document_fixture(%{status: "completed", title: title})
    page = page_fixture(document, %{page_number: 1})

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: text
      })

    page
  end

  # Parks the embedding stub on `text` until this test releases it, so the
  # LiveView can be observed mid-inference.
  defp install_barrier(text) do
    barrier = make_ref()
    TestEnv.put_env(:embedding_stub_barrier, {text, self(), barrier})
    barrier
  end
end
