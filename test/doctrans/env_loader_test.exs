defmodule Doctrans.EnvLoaderTest do
  use ExUnit.Case, async: false

  alias Doctrans.EnvLoader

  @env_keys ["OPENAI_HOST", "OPENAI_API_KEY", "UNRELATED_VAR"]

  setup do
    prev_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)

    prev_config = %{
      openai: Application.get_env(:doctrans, :openai),
      embedding: Application.get_env(:doctrans, :embedding)
    }

    for key <- @env_keys, do: System.delete_env(key)
    Application.put_env(:doctrans, :openai, base_url: "http://config-default:8000", api_key: nil)

    Application.put_env(:doctrans, :embedding,
      base_url: "http://config-default:8000",
      api_key: nil
    )

    tmp =
      Path.join(System.tmp_dir!(), "env_loader_test_#{System.unique_integer([:positive])}.env")

    on_exit(fn ->
      for {key, value} <- prev_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      restore_config(:openai, prev_config.openai)
      restore_config(:embedding, prev_config.embedding)
      File.rm(tmp)
    end)

    %{path: tmp}
  end

  defp restore_config(key, value) do
    if value,
      do: Application.put_env(:doctrans, key, value),
      else: Application.delete_env(:doctrans, key)
  end

  test "applies file variables to the environment and config when not set", %{path: path} do
    File.write!(path, """
    # a comment

    OPENAI_HOST=http://from-file:1234
    OPENAI_API_KEY=sk-from-file
    UNRELATED_VAR=unrelated
    """)

    assert :ok = EnvLoader.load(path)

    assert System.get_env("OPENAI_HOST") == "http://from-file:1234"
    assert System.get_env("OPENAI_API_KEY") == "sk-from-file"
    assert System.get_env("UNRELATED_VAR") == "unrelated"

    assert Application.get_env(:doctrans, :openai) == [
             base_url: "http://from-file:1234",
             api_key: "sk-from-file"
           ]

    assert Application.get_env(:doctrans, :embedding) == [
             base_url: "http://from-file:1234",
             api_key: "sk-from-file"
           ]
  end

  test ".env file values override real environment variables", %{path: path} do
    System.put_env("OPENAI_HOST", "http://from-real-env:9999")
    System.put_env("OPENAI_API_KEY", "sk-real")

    File.write!(path, """
    OPENAI_HOST=http://from-file:1234
    OPENAI_API_KEY=sk-from-file
    """)

    assert :ok = EnvLoader.load(path)

    assert System.get_env("OPENAI_HOST") == "http://from-file:1234"
    assert System.get_env("OPENAI_API_KEY") == "sk-from-file"

    openai = Application.get_env(:doctrans, :openai)
    assert Keyword.fetch!(openai, :base_url) == "http://from-file:1234"
    assert Keyword.fetch!(openai, :api_key) == "sk-from-file"
  end

  test "a key-only line sets an empty value when the variable is unset", %{path: path} do
    File.write!(path, "OPENAI_API_KEY\n")

    assert :ok = EnvLoader.load(path)
    assert System.get_env("OPENAI_API_KEY") == ""
  end

  test "a missing file is a no-op", %{path: path} do
    assert :ok = EnvLoader.load(path)
    refute System.get_env("OPENAI_HOST")
    refute System.get_env("OPENAI_API_KEY")

    assert Application.get_env(:doctrans, :openai, []) == [
             base_url: "http://config-default:8000",
             api_key: nil
           ]
  end
end
