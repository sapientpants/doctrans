defmodule Doctrans.Config do
  @moduledoc """
  Runtime configuration access for the application.

  Use `Doctrans.Config.OpenAI`, `Doctrans.Config.Embedding`, and
  `Doctrans.Config.Uploads` at call sites. Model names, the shared API endpoint,
  and upload settings are defined in `config/config.exs`; runtime configuration
  applies environment overrides. Accessors read the current application settings
  on every call, so release configuration and test overrides take effect.

  Required settings fail explicitly when missing instead of silently choosing a
  different model or storage directory. Optional settings and model fallback
  rules are defined in the corresponding accessor module.
  """

  @doc false
  @spec get(atom(), atom()) :: term()
  def get(section, key), do: Application.get_env(:doctrans, section, [])[key]

  @doc false
  @spec fetch!(atom(), atom()) :: term()
  def fetch!(section, key) do
    :doctrans |> Application.fetch_env!(section) |> Keyword.fetch!(key)
  end
end
