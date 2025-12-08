defmodule Doctrans.Resilience.HealthCheck do
  @moduledoc """
  Health check functions for monitoring system dependencies.

  Provides functions to check the health of:
  - Ollama API (AI model service)
  - Database connection
  - File system (uploads directory)

  ## Usage

      iex> HealthCheck.check_all()
      %{
        ollama: {:ok, %{models: [...]}},
        database: :ok,
        filesystem: :ok
      }

      iex> HealthCheck.healthy?()
      true
  """

  require Logger

  alias Doctrans.Repo
  alias Doctrans.Resilience.CircuitBreaker

  @doc """
  Runs all health checks and returns results.
  """
  @spec check_all() :: %{
          ollama: {:ok, map()} | {:error, term()},
          database: :ok | {:error, term()},
          filesystem: :ok | {:error, term()}
        }
  def check_all do
    %{
      ollama: check_ollama(),
      database: check_database(),
      filesystem: check_filesystem()
    }
  end

  @doc """
  Returns true if all health checks pass.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    results = check_all()

    Enum.all?(results, fn
      {_name, :ok} -> true
      {_name, {:ok, _}} -> true
      {_name, {:error, _}} -> false
    end)
  end

  @doc """
  Checks Ollama API availability.

  Returns `{:ok, %{available: true, models: [...]}}` on success,
  or `{:error, reason}` on failure.
  """
  @spec check_ollama() :: {:ok, map()} | {:error, term()}
  def check_ollama do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        # Check circuit breaker status first
        circuit_status = CircuitBreaker.status(:ollama_api)

        if circuit_status == :blown do
          {:error, :circuit_open}
        else
          # Actually check Ollama connectivity
          config = Application.get_env(:doctrans, :ollama, [])
          url = "#{config[:base_url]}/api/tags"

          case Req.get(url, receive_timeout: 5_000) do
            {:ok, %{status: 200, body: body}} ->
              models = get_in(body, ["models"]) || []
              model_names = Enum.map(models, & &1["name"])
              {:ok, %{available: true, models: model_names, circuit: circuit_status}}

            {:ok, %{status: status}} ->
              {:error, "HTTP #{status}"}

            {:error, reason} ->
              {:error, reason}
          end
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:doctrans, :health_check, :completed],
      %{duration_ms: duration},
      %{check: :ollama, result: elem(result, 0)}
    )

    result
  end

  @doc """
  Checks database connectivity.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  @spec check_database() :: :ok | {:error, term()}
  def check_database do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        # Simple query to check connectivity
        Repo.query!("SELECT 1")
        :ok
      rescue
        e -> {:error, Exception.message(e)}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:doctrans, :health_check, :completed],
      %{duration_ms: duration},
      %{check: :database, result: if(result == :ok, do: :ok, else: :error)}
    )

    result
  end

  @doc """
  Checks filesystem health (uploads directory is writable).

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  @spec check_filesystem() :: :ok | {:error, term()}
  def check_filesystem do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        uploads_dir = Doctrans.Documents.uploads_dir()

        # Check directory exists
        unless File.dir?(uploads_dir) do
          throw({:error, "Uploads directory does not exist: #{uploads_dir}"})
        end

        # Try to write a test file
        test_file = Path.join(uploads_dir, ".health_check_#{System.os_time(:nanosecond)}")

        case File.write(test_file, "health check") do
          :ok ->
            File.rm(test_file)
            :ok

          {:error, reason} ->
            {:error, "Cannot write to uploads directory: #{reason}"}
        end
      rescue
        e -> {:error, Exception.message(e)}
      catch
        {:error, reason} -> {:error, reason}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:doctrans, :health_check, :completed],
      %{duration_ms: duration},
      %{check: :filesystem, result: if(result == :ok, do: :ok, else: :error)}
    )

    result
  end

  @doc """
  Returns a summary of circuit breaker states.
  """
  @spec circuit_breaker_status() :: map()
  def circuit_breaker_status do
    CircuitBreaker.status_all()
  end
end
