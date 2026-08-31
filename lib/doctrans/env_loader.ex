defmodule Doctrans.EnvLoader do
  @moduledoc """
  Loads variables from a `.env` file and applies the OpenAI/OMLX ones to
  the application config.

  Real environment variables always win: a variable that is already present
  in the environment is never overwritten by the file (standard dotenv
  convention). The config defaults in `config/config.exs` are resolved from
  the environment at boot, so this ordering keeps a stale `.env` from
  clobbering variables set by the deploy environment.

  The same `OPENAI_HOST` / `OPENAI_API_KEY` pair is applied to both the
  `:openai` and `:embedding` config keys, which is fine for the single OMLX
  endpoint they both talk to.
  """

  @env_path Path.join(__DIR__, "../../.env")

  def load(path \\ @env_path) do
    parse_env_file(path)

    apply_to(:openai)
    apply_to(:embedding)

    :ok
  end

  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split(~r/\r?\n/, trim: true)
        |> Enum.reject(&blank_or_comment?/1)
        |> Enum.each(&put_env_line/1)

      _ ->
        :ok
    end
  end

  defp blank_or_comment?(line) do
    String.starts_with?(line, "#") or String.trim(line) == ""
  end

  defp put_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> put_unless_set(key, String.trim(value))
      [key] -> put_unless_set(key, "")
      _ -> :ok
    end
  end

  # The real environment wins over `.env` file values.
  defp put_unless_set(key, value) do
    if System.get_env(key) do
      :ok
    else
      System.put_env(key, value)
    end
  end

  defp apply_to(config_key) do
    current = Application.get_env(:doctrans, config_key, [])
    current = put_if_present(current, :api_key, "OPENAI_API_KEY")
    current = put_if_present(current, :base_url, "OPENAI_HOST")
    Application.put_env(:doctrans, config_key, current)
  end

  defp put_if_present(keyword, key, env_var) do
    case System.get_env(env_var) do
      nil -> keyword
      value -> Keyword.put(keyword, key, value)
    end
  end
end
