defmodule Doctrans.ProviderConfig do
  @moduledoc false

  import Logger, only: [warning: 1]

  @required_keys [
    :base_url,
    :vision_model,
    :translation_model,
    :chat_model,
    :embedding_model
  ]

  @doc """
  Validates provider configuration and installs circuit breakers.
  Called during application startup.
  """
  def validate do
    Doctrans.Resilience.CircuitBreaker.install_fuses()

    provider = Application.get_env(:doctrans, :provider, :ollama)
    config = Application.get_env(:doctrans, provider, [])

    if config == [] do
      warning(
        "Provider config for #{inspect(provider)} is empty. " <>
          "Check config/config.exs for :#{provider} settings."
      )
    end

    missing =
      Enum.reject(@required_keys, &Keyword.has_key?(config, &1))

    if missing != [] do
      warning(
        "Provider config for #{inspect(provider)} is missing keys: #{inspect(missing)}. " <>
          "This may cause runtime errors."
      )
    end

    env = Application.get_env(:doctrans, :env, :dev)

    if env == :prod and missing != [] do
      raise ArgumentError,
            "Provider config for #{inspect(provider)} is missing required keys: #{inspect(missing)}. " <>
              "Set #{Enum.map_join(missing, ", ", &":#{&1}")} in config/config.exs under :#{provider}."
    end

    if Application.get_env(:doctrans, :embedding) != nil do
      warning(
        "The :embedding config section is deprecated and has been removed. " <>
          "Per-provider embedding config is now set under :#{provider} with :embedding_model key. " <>
          "Remove the :embedding key from config/config.exs."
      )
    end
  end
end
