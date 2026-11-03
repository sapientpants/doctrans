defmodule DoctransWeb.ConnCase do
  @moduledoc """
  The case template for tests that drive the application through a connection
  or a LiveView.

  Beyond `Phoenix.ConnTest` and `Phoenix.LiveViewTest`, it does three things of
  this project's own. It registers the test with `Doctrans.TestEnv` and installs
  the default mock stubs through `Doctrans.DataCase.setup_sandbox/1`, so a
  global override is refused from an `async: true` test and every collaborator
  answers from the first call. It wraps `live/3` and the redirect helpers so a
  mount of the dashboard from an async test fails at once: dashboard PubSub is
  global even when SQL sandboxes are isolated. And `queue_only/2` is how a test
  submits a form whose handler enqueues a job without running that job inline.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DoctransWeb.Endpoint

      use DoctransWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest

      import Phoenix.LiveViewTest,
        except: [
          live: 1,
          live: 2,
          live: 3,
          live_redirect: 2,
          follow_redirect: 2,
          follow_redirect: 3
        ]

      import DoctransWeb.ConnCase
    end
  end

  setup tags do
    Doctrans.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # Check the mounted module, not how the caller spelled a URL or built its
  # connection. Dashboard PubSub is global even when SQL sandboxes are isolated.
  defmacro live(conn, path \\ nil, opts \\ []) do
    quote do
      require Phoenix.LiveViewTest

      Phoenix.LiveViewTest.live(unquote(conn), unquote(path), unquote(opts))
      |> DoctransWeb.ConnCase.check_live_result!()
    end
  end

  def live_redirect(view, opts) do
    view |> Phoenix.LiveViewTest.live_redirect(opts) |> check_live_result!()
  end

  defmacro follow_redirect(reason, conn, to \\ nil) do
    quote do
      require Phoenix.LiveViewTest

      Phoenix.LiveViewTest.follow_redirect(unquote(reason), unquote(conn), unquote(to))
      |> DoctransWeb.ConnCase.check_live_result!()
    end
  end

  def check_live_result!({:ok, %{module: DoctransWeb.DocumentLive.Index}, _html} = result) do
    if Doctrans.TestEnv.async?() do
      raise ArgumentError,
            "Dashboard LiveView tests must use async: false because PubSub is global"
    end

    result
  end

  def check_live_result!(result), do: result

  @doc """
  Runs `fun` with Oban in `:manual` mode for both the test and the LiveView.

  Oban runs `testing: :inline` in the suite, so an insert executes the job then
  and there, and a job a LiveView event enqueues -- an upload's extraction, a
  retry's model call -- would run for real. Both processes have to opt out:
  `Oban.Config.get_engine/1` reads `self()` *and* `$callers`, and the LiveView
  names the test among its callers, so setting the mode in only one of them
  leaves the other voting for inline. `:sys.replace_state/2` is only a way to
  run `Process.put/2` in the view; the socket state is returned unchanged, and
  the flag leaves with the view at the end of the test.
  """
  def queue_only(view, fun) do
    :sys.replace_state(view.pid, fn state ->
      Process.put(:oban_testing, :manual)
      state
    end)

    Oban.Testing.with_testing_mode(:manual, fun)
  end

  @doc """
  Renders a single element, for assertions scoped to one claim on the page.

  Named for what it returns -- markup, attributes included, not text -- because
  a `refute` against an element's text would also be satisfied by a class name.
  """
  def element_html(view, selector) do
    view |> Phoenix.LiveViewTest.element(selector) |> Phoenix.LiveViewTest.render()
  end
end
