defmodule Doctrans.EnvLoader do
  @moduledoc """
  Loads optional `.env` defaults before runtime configuration in every environment.

  Inherited variables take precedence, including empty values. The default file is
  `.env` in the working directory; `DOCTRANS_ENV_FILE` selects another path.
  API setting conflicts report the winning source without logging values.
  """

  require Logger

  def load(path \\ System.get_env("DOCTRANS_ENV_FILE", ".env")) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split(~r/\r?\n/, trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
        |> Enum.each(&put_env_line/1)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read environment file", path: path
    end

    :ok
  end

  defp put_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> put_env(String.trim(key), String.trim(value))
      [key] -> put_env(key, "")
    end
  end

  defp put_env(key, value) do
    case System.get_env(key) do
      nil ->
        System.put_env(key, value)

      inherited when inherited != value and key in ["OPENAI_HOST", "OPENAI_API_KEY"] ->
        Logger.warning(
          "Inherited #{key} overrides a different value in the environment file. " <>
            "Unset #{key} before starting Doctrans to use the file value."
        )

      _ ->
        :ok
    end
  end
end
