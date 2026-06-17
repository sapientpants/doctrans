defmodule Doctrans.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias Doctrans.Resilience.CircuitBreaker

  @impl true
  def start(_type, _args) do
    # Install circuit breakers before starting workers
    CircuitBreaker.install_fuses()

    # Validate provider configuration at startup
    validate_provider_config()

    children = [
      DoctransWeb.Telemetry,
      Doctrans.Repo,
      {DNSCluster, query: Application.get_env(:doctrans, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Doctrans.PubSub},
      # Oban for persistent job queuing
      {Oban, Application.get_env(:doctrans, Oban)},
      # Task supervisor for background processing
      {Task.Supervisor, name: Doctrans.TaskSupervisor},
      # Background worker for processing books
      Doctrans.Processing.Worker,
      # Background worker for generating embeddings
      Doctrans.Search.EmbeddingWorker,
      # Scheduled worker for cleaning up orphaned files
      Doctrans.Documents.SweeperWorker,
      # Periodic health check worker
      Doctrans.Resilience.HealthCheckWorker,
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

  defp validate_provider_config do
    provider = Application.get_env(:doctrans, :provider, :ollama)
    config = Application.get_env(:doctrans, provider, [])

    if config == [] do
      Logger.warning(
        "Provider config for #{inspect(provider)} is empty. " <>
          "Check config/config.exs for :#{provider} settings."
      )
    end

    required_keys = [:base_url, :vision_model, :translation_model, :chat_model, :embedding_model]

    missing =
      Enum.reject(required_keys, &Keyword.has_key?(config, &1))

    if missing != [] do
      Logger.warning(
        "Provider config for #{inspect(provider)} is missing keys: #{inspect(missing)}. " <>
          "This may cause runtime errors."
      )
    end
  end
end
