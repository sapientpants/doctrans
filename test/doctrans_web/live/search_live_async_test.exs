defmodule DoctransWeb.SearchLiveAsyncTest do
  @moduledoc """
  Covers the asynchronous search path: one embedding per submitted query, a
  loading state that renders while inference waits, a superseded query whose
  inference call is cancelled rather than left running, and the payload check
  that stops a cancelled search from reporting under the query that replaced it.

  Also covers how a finished search reports itself -- an outage, no matches, or
  the keyword-only mode `Doctrans.Search.search_with_count/2` falls back to when
  the query cannot be embedded, which is a success the reader must not mistake
  for the whole answer.

  Not async: each test swaps global `Application` env (the embedding module, or
  the stub's barrier) to observe or hold an embedding call.
  """
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Doctrans.Documents.Pages
  alias Doctrans.Repo
  alias Doctrans.Search.{EmbeddingDimensionStub, EmbeddingErrorStub, EmbeddingProbe}
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
      payload = {:ok, {"old query", 1, search_page([result_stub()], 5)}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.results == []
      assert socket.assigns.total_count == 0
      assert socket.assigns.searching
      refute socket.assigns.searched
    end

    test "ignores a result reported for a page the view has moved off" do
      socket = search_socket("same query", 2)
      payload = {:ok, {"same query", 1, search_page([result_stub()], 5)}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.results == []
      assert socket.assigns.total_count == 0
    end

    test "applies a result reported for the current query and page" do
      result = result_stub()
      socket = search_socket("current query", 2)
      payload = {:ok, {"current query", 2, search_page([result], 5)}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.results == [result]
      assert socket.assigns.total_count == 5
      assert socket.assigns.retrieval == :hybrid
      refute socket.assigns.searching
      assert socket.assigns.searched
    end

    test "carries the retrieval mode the search reported" do
      socket = search_socket("degraded query", 1)
      payload = {:ok, {"degraded query", 1, search_page([result_stub()], 1, :keyword_only)}}

      assert {:noreply, socket} = SearchLive.handle_async(:search, payload, socket)

      assert socket.assigns.retrieval == :keyword_only
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

    test "a failure clears the degraded retrieval mode behind it" do
      socket =
        "degraded then failing query"
        |> search_socket(1)
        |> Phoenix.Component.assign(:retrieval, :keyword_only)

      payload = {:ok, {"degraded then failing query", 1, {:error, :timeout}}}

      {{:noreply, socket}, _log} =
        with_log(fn -> SearchLive.handle_async(:search, payload, socket) end)

      # The error panel replaces the results, so the notice describing how they
      # were retrieved has nothing left to describe.
      assert socket.assigns.search_error
      assert socket.assigns.retrieval == :hybrid
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
    test "renders the error panel when the search statement fails", %{conn: conn} do
      "Contains failingstatementterm in the text"
      |> searchable_page("Failing Statement Doc")
      |> embed()

      # The embedding succeeds and the query fails for a real reason, which is
      # what separates an outage from the degraded keyword-only mode: there are
      # no results to show, so the error panel stands alone.
      TestEnv.put_env(:embedding_module, EmbeddingDimensionStub)

      {:ok, view, _html} = live(conn, ~p"/search?q=failingstatementterm")

      capture_log(fn -> render_async(view, @async_timeout) end)

      assert has_element?(view, "#search-error")
      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#search-loading")
      refute has_element?(view, "#search-empty")
      refute has_element?(view, "#search-degraded")
    end
  end

  describe "keyword-only retrieval" do
    test "tells the reader the results are keyword matches only", %{conn: conn} do
      page = searchable_page("Contains degradedterm in the text", "Degraded Doc")
      inference_down_for("degradedterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=degradedterm")

      capture_log(fn -> render_async(view, @async_timeout) end)

      assert has_element?(view, "#search-results")
      assert has_element?(view, "#search-result-#{page.id}")
      assert has_element?(view, "#search-degraded")

      # Degraded, not failed: the results stand, and nothing claims otherwise.
      refute has_element?(view, "#search-error")
      refute has_element?(view, "#flash-error")
    end

    test "tells the reader why a keyword-only search found nothing", %{conn: conn} do
      searchable_page("Contains something else entirely", "Unrelated Doc")
      inference_down_for("unmatchedterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=unmatchedterm")

      capture_log(fn -> render_async(view, @async_timeout) end)

      # Without the notice this reads as "nothing in my library matches", when
      # what it really means is that half the search never ran.
      assert has_element?(view, "#search-empty")
      assert has_element?(view, "#search-degraded")
      refute has_element?(view, "#search-error")
    end

    test "says nothing about retrieval until the search reports", %{conn: conn} do
      searchable_page("Contains degradedterm in the text", "Degraded Doc")
      inference_down_for("degradedterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=degradedterm")

      assert has_element?(view, "#search-loading")
      refute has_element?(view, "#search-degraded")

      capture_log(fn -> render_async(view, @async_timeout) end)
      assert has_element?(view, "#search-degraded")
    end

    test "the notice does not outlive the query that produced it", %{conn: conn} do
      searchable_page("Contains degradedterm in the text", "Degraded Doc")
      searchable_page("Contains healthyterm in the text", "Healthy Doc")

      # Only the first query fails to embed, so the second one searches normally.
      inference_down_for("degradedterm")

      {:ok, view, _html} = live(conn, ~p"/search?q=degradedterm")
      capture_log(fn -> render_async(view, @async_timeout) end)
      assert has_element?(view, "#search-degraded")

      view |> element("#search-form") |> render_submit(%{q: "healthyterm"})
      assert render_async(view, @async_timeout) =~ "Healthy Doc"

      refute has_element?(view, "#search-degraded")
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
        retrieval: :hybrid,
        searching: true,
        searched: false,
        search_error: false,
        flash: %{}
      }
    }
  end

  # The plan fails this query alone, so every other embedding in the VM keeps
  # behaving normally while the override stands.
  defp inference_down_for(query) do
    TestEnv.put_env(:embedding_module, EmbeddingErrorStub)
    TestEnv.put_env(:embedding_error_plan, [{query, :circuit_open}])
  end

  defp search_page(results, total_count, retrieval \\ :hybrid) do
    {:ok, %{results: results, total_count: total_count, retrieval: retrieval}}
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

  # The statement only compares vectors for pages that have one, so a page must
  # be indexed before a width mismatch can reach Postgres at all.
  defp embed(page) do
    page
    |> Ecto.Changeset.change(embedding: Pgvector.new(List.duplicate(0.1, 1024)))
    |> Repo.update!()
  end

  # Parks the embedding stub on `text` until this test releases it, so the
  # LiveView can be observed mid-inference.
  defp install_barrier(text) do
    barrier = make_ref()
    TestEnv.put_env(:embedding_stub_barrier, {text, self(), barrier})
    barrier
  end
end
