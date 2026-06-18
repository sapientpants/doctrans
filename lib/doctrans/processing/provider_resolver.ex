defmodule Doctrans.Processing.ProviderResolver do
  @moduledoc """
  Resolves the active provider module from config.

  Uses a string-based config key (`:provider`) to avoid compile-time
  dependencies between callers and provider modules, keeping module
  dependency counts within Credo limits.
  """

  @doc """
  Returns the provider module for the configured provider.

  Checks `:provider_module` first (for test mocks), then falls back to
  `:provider` string config (for dev/prod).

  Returns `{:ok, module}` on success or `{:error, reason}` on failure.
  """
  @spec resolve() :: {:ok, module()} | {:error, term()}
  def resolve do
    case Application.get_env(:doctrans, :provider_module) do
      nil ->
        case Application.get_env(:doctrans, :provider, :ollama) do
          provider when provider in [:ollama, :unsloth] ->
            {:ok, resolve_by_name!(provider)}

          other ->
            {:error, "Unknown provider: #{inspect(other)}"}
        end

      module ->
        {:ok, module}
    end
  end

  @doc """
  Like `resolve/0` but raises on failure.

  Use this at startup or in explicit crash-at-startup sites.
  """
  @spec resolve!() :: module()
  def resolve! do
    case resolve() do
      {:ok, module} -> module
      {:error, reason} -> raise ArgumentError, "Failed to resolve provider: #{reason}"
    end
  end

  defp resolve_by_name!(:ollama), do: Doctrans.Processing.Ollama
  defp resolve_by_name!(:unsloth), do: Doctrans.Processing.Unsloth
end
