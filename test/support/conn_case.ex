defmodule DoctransWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DoctransWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
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
  Puts the LiveView process itself into Oban's `:manual` testing mode.

  `Oban.Testing.with_testing_mode/2` records the mode in the *calling* process's
  dictionary, but a `render_submit/1` is handled in the LiveView process, and
  that is the process which inserts the job -- so setting it in the test process
  is what lets a submitted upload run its worker inline. `:sys.replace_state/2`
  is only a way to run `Process.put/2` over there; the socket state is returned
  unchanged, and the flag leaves with the view at the end of the test.
  """
  def put_oban_manual_mode(view) do
    :sys.replace_state(view.pid, fn state ->
      Process.put(:oban_testing, :manual)
      state
    end)

    view
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
