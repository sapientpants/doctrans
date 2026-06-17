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
  """
  @spec resolve() :: module()
  def resolve do
    case Application.get_env(:doctrans, :provider_module) do
      nil -> resolve_by_name(Application.get_env(:doctrans, :provider, :ollama))
      module -> module
    end
  end

  defp resolve_by_name(:ollama), do: Doctrans.Processing.Ollama
  defp resolve_by_name(:unsloth), do: Doctrans.Processing.Unsloth
  defp resolve_by_name(other), do: raise("Unknown provider: #{inspect(other)}")
end
