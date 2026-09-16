defmodule DoctransWeb.Router do
  use DoctransWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DoctransWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, DoctransWeb.ContentSecurityPolicy.headers()

    plug DoctransWeb.Plugs.SetLocale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DoctransWeb do
    pipe_through :browser

    live_session :default, on_mount: [{DoctransWeb.Live.Hooks.SetLocale, :default}] do
      live "/", DocumentLive.Index, :index
      live "/search", SearchLive, :index
      live "/documents/:id", DocumentLive.Show, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", DoctransWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:doctrans, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    # Aliased inside the block rather than at the top of the module: outside a
    # dev build this code does not exist, and the alias would be unused.
    alias DoctransWeb.Plugs.DashboardCsp

    # The widened policy is scoped to the dashboard's own path rather than to
    # `/dev`, so a dev route added later cannot inherit it just by being written
    # in the same block. The mailbox preview below keeps the base policy.
    pipeline :dashboard_csp do
      plug DashboardCsp
    end

    scope "/dev/dashboard" do
      pipe_through [:browser, :dashboard_csp]

      # The key is read from the plug rather than repeated as a literal: the two
      # have to agree exactly, or LiveDashboard reads an assign nobody set, the
      # nonce attributes drop out of the markup entirely, and the browser
      # refuses the script with nothing logged on the server at all.
      live_dashboard "/",
        metrics: DoctransWeb.Telemetry,
        csp_nonce_assign_key: DashboardCsp.assign_key()
    end

    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
