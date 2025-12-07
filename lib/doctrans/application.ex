defmodule Doctrans.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DoctransWeb.Telemetry,
      Doctrans.Repo,
      {DNSCluster, query: Application.get_env(:doctrans, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Doctrans.PubSub},
      # Task supervisor for background processing
      {Task.Supervisor, name: Doctrans.TaskSupervisor},
      # Background worker for processing books
      Doctrans.Processing.Worker,
      # Background worker for generating embeddings
      Doctrans.Search.EmbeddingWorker,
      # Scheduled worker for cleaning up orphaned files
      Doctrans.Documents.SweeperWorker,
      # Start to serve requests, typically the last entry
      DoctransWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Doctrans.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DoctransWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
