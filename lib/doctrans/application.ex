defmodule Doctrans.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Doctrans.ProviderConfig.validate()

    children = [
      DoctransWeb.Telemetry,
      Doctrans.Repo,
      {DNSCluster, query: Application.get_env(:doctrans, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Doctrans.PubSub},
      {Oban, Application.get_env(:doctrans, Oban)},
      {Task.Supervisor, name: Doctrans.TaskSupervisor},
      Doctrans.Processing.Worker,
      Doctrans.Search.EmbeddingWorker,
      Doctrans.Documents.SweeperWorker,
      Doctrans.Resilience.HealthCheckWorker,
      DoctransWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Doctrans.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DoctransWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
