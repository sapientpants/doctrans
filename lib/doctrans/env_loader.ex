defmodule Doctrans.EnvLoader do
  @moduledoc false

  @env_path Path.join(__DIR__, "../../.env")

  def load do
    parse_env_file()

    apply_to(:openai)
    apply_to(:embedding)

    :ok
  end

  defp parse_env_file do
    case File.read(@env_path) do
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
      [key, value] -> System.put_env(key, String.trim(value))
      [key] -> System.put_env(key, "")
      _ -> :ok
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
