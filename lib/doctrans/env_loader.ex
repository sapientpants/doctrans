defmodule Doctrans.EnvLoader do
  @moduledoc """
  Loads variables from a `.env` file and applies the OpenAI/OMLX ones to
  the application config.

  Only development loads `.env`; test and production leave the environment
  and application config untouched. Inherited environment variables take
  precedence over file values, including explicitly empty variables.
  In development, the loader re-applies `OPENAI_HOST` / `OPENAI_API_KEY`
  to the application config at startup. Releases use `config/runtime.exs`.

  The same `OPENAI_HOST` / `OPENAI_API_KEY` pair is applied to both the
  `:openai` and `:embedding` config keys, which is fine for the single OMLX
  endpoint they both talk to.
  """

  @env_path Path.join(__DIR__, "../../.env")

  def load(path \\ @env_path) do
    if Application.get_env(:doctrans, :env) == :dev do
      parse_env_file(path)

      apply_to(:openai)
      apply_to(:embedding)
    end

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
      [key, value] -> put_env(key, String.trim(value))
      [key] -> put_env(key, "")
      _ -> :ok
    end
  end

  defp put_env(key, value) do
    if is_nil(System.get_env(key)), do: System.put_env(key, value)
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
