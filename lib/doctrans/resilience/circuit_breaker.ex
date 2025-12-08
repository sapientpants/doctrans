defmodule Doctrans.Resilience.CircuitBreaker do
  @moduledoc """
  Circuit breaker wrapper around the `:fuse` library.

  Provides protection against cascading failures by "breaking" the circuit
  when too many failures occur, preventing further calls until the service recovers.

  ## Fuse Names

  - `:ollama_api` - Protects Ollama API calls (extraction, translation)
  - `:embedding_api` - Protects embedding generation calls

  ## Configuration

  Configure in `config/config.exs`:

      config :doctrans, :circuit_breakers,
        ollama_api: [
          strategy: {:standard, 5, 60_000},  # 5 failures in 60s = blown
          refresh: 30_000                     # Check recovery every 30s
        ],
        embedding_api: [
          strategy: {:standard, 3, 30_000},
          refresh: 15_000
        ]

  ## States

  - `:ok` - Circuit is closed, requests flow through
  - `:blown` - Circuit is open, requests are rejected immediately
  """

  require Logger

  @fuse_names [:ollama_api, :embedding_api]

  @default_config %{
    ollama_api: [
      strategy: {:standard, 5, 60_000},
      refresh: 30_000
    ],
    embedding_api: [
      strategy: {:standard, 3, 30_000},
      refresh: 15_000
    ]
  }

  @doc """
  Installs all configured fuses at application startup.

  Should be called from `Application.start/2` before starting workers.
  """
  @spec install_fuses() :: :ok
  def install_fuses do
    config = get_config()

    for name <- @fuse_names do
      fuse_config = Map.get(config, name, @default_config[name])
      strategy = Keyword.get(fuse_config, :strategy, {:standard, 5, 60_000})
      refresh = Keyword.get(fuse_config, :refresh, 30_000)

      opts = {strategy, {:reset, refresh}}

      case :fuse.install(name, opts) do
        :ok ->
          Logger.info("Installed circuit breaker: #{name}")

        {:error, :already_installed} ->
          Logger.debug("Circuit breaker already installed: #{name}")
      end
    end

    :ok
  end

  @doc """
  Executes a function with circuit breaker protection.

  If the circuit is open (blown), returns `{:error, :circuit_open}` immediately
  without executing the function.

  On success, returns the function result.
  On failure, melts the fuse and returns the error.

  ## Examples

      iex> CircuitBreaker.call(:ollama_api, fn -> {:ok, "result"} end)
      {:ok, "result"}

      iex> CircuitBreaker.call(:ollama_api, fn -> {:error, :timeout} end)
      {:error, :timeout}

      # After too many failures:
      iex> CircuitBreaker.call(:ollama_api, fn -> :never_called end)
      {:error, :circuit_open}
  """
  @spec call(atom(), (-> any())) :: any()
  def call(fuse_name, fun) when is_atom(fuse_name) and is_function(fun, 0) do
    case :fuse.ask(fuse_name, :sync) do
      :ok ->
        execute_with_fuse(fuse_name, fun)

      :blown ->
        Logger.warning("Circuit breaker #{fuse_name} is open, rejecting request")

        :telemetry.execute(
          [:doctrans, :circuit_breaker, :rejected],
          %{count: 1},
          %{fuse_name: fuse_name}
        )

        {:error, :circuit_open}

      {:error, :not_found} ->
        Logger.warning("Circuit breaker #{fuse_name} not installed, executing without protection")
        fun.()
    end
  end

  defp execute_with_fuse(fuse_name, fun) do
    result = fun.()

    case result do
      {:ok, _} ->
        result

      :ok ->
        result

      {:error, reason} = error ->
        melt(fuse_name, reason)
        error

      other ->
        other
    end
  end

  @doc """
  Reports a failure to the circuit breaker (melts the fuse).

  Call this when an operation fails to contribute to the failure count.
  """
  @spec melt(atom(), term()) :: :ok
  def melt(fuse_name, reason \\ :unknown) do
    :fuse.melt(fuse_name)

    :telemetry.execute(
      [:doctrans, :circuit_breaker, :failure],
      %{count: 1},
      %{fuse_name: fuse_name, reason: inspect(reason)}
    )

    # Check if the fuse just blew
    case :fuse.ask(fuse_name, :sync) do
      :blown ->
        Logger.error("Circuit breaker #{fuse_name} has blown open!")

        :telemetry.execute(
          [:doctrans, :circuit_breaker, :blown],
          %{count: 1},
          %{fuse_name: fuse_name}
        )

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Manually resets a circuit breaker.

  Use this to force a recovery, e.g., after a health check confirms the service is back.
  """
  @spec reset(atom()) :: :ok
  def reset(fuse_name) do
    :fuse.reset(fuse_name)
    Logger.info("Circuit breaker #{fuse_name} has been reset")

    :telemetry.execute(
      [:doctrans, :circuit_breaker, :reset],
      %{count: 1},
      %{fuse_name: fuse_name}
    )

    :ok
  end

  @doc """
  Returns the current status of a circuit breaker.

  ## Returns

  - `:ok` - Circuit is closed
  - `:blown` - Circuit is open
  - `:not_found` - Fuse not installed
  """
  @spec status(atom()) :: :ok | :blown | :not_found
  def status(fuse_name) do
    case :fuse.ask(fuse_name, :sync) do
      :ok -> :ok
      :blown -> :blown
      {:error, :not_found} -> :not_found
    end
  end

  @doc """
  Returns the status of all circuit breakers.
  """
  @spec status_all() :: %{atom() => :ok | :blown | :not_found}
  def status_all do
    Map.new(@fuse_names, fn name -> {name, status(name)} end)
  end

  @doc """
  Returns the list of configured fuse names.
  """
  @spec fuse_names() :: [atom()]
  def fuse_names, do: @fuse_names

  defp get_config do
    app_config = Application.get_env(:doctrans, :circuit_breakers, [])

    @default_config
    |> Map.new()
    |> Map.merge(Map.new(app_config))
  end
end
