defmodule Doctrans.EnvLoaderTest do
  use ExUnit.Case, async: false

  alias Doctrans.EnvLoader

  @env_keys ["OPENAI_HOST", "OPENAI_API_KEY", "UNRELATED_VAR", "DATABASE_URL", "SECRET_KEY_BASE"]

  setup do
    prev_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)

    prev_config = %{
      env: Application.get_env(:doctrans, :env),
      openai: Application.get_env(:doctrans, :openai),
      embedding: Application.get_env(:doctrans, :embedding)
    }

    Application.put_env(:doctrans, :env, :dev)

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

      restore_config(:env, prev_config.env)
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

  test "real environment variables take precedence over file values", %{path: path} do
    System.put_env("OPENAI_HOST", "http://from-real-env:9999")
    System.put_env("OPENAI_API_KEY", "sk-real")

    File.write!(path, """
    OPENAI_HOST=http://from-file:1234
    OPENAI_API_KEY=sk-from-file
    """)

    assert :ok = EnvLoader.load(path)

    assert System.get_env("OPENAI_HOST") == "http://from-real-env:9999"
    assert System.get_env("OPENAI_API_KEY") == "sk-real"

    openai = Application.get_env(:doctrans, :openai)
    assert Keyword.fetch!(openai, :base_url) == "http://from-real-env:9999"
    assert Keyword.fetch!(openai, :api_key) == "sk-real"
  end

  test "explicitly empty environment variables take precedence", %{path: path} do
    System.put_env("OPENAI_API_KEY", "")
    File.write!(path, "OPENAI_API_KEY=sk-from-file\n")

    assert :ok = EnvLoader.load(path)
    assert System.get_env("OPENAI_API_KEY") == ""

    for key <- [:openai, :embedding] do
      assert Application.fetch_env!(:doctrans, key)[:api_key] == ""
    end
  end

  for env <- [:prod, :test] do
    test "#{env} ignores files and does not re-apply config", %{path: path} do
      Application.put_env(:doctrans, :env, unquote(env))
      System.put_env("OPENAI_HOST", "http://inherited:8000")
      File.write!(path, "OPENAI_HOST=http://file:8000\nUNRELATED_VAR=file\n")
      previous = Application.get_all_env(:doctrans)

      assert :ok = EnvLoader.load(path)
      assert System.get_env("OPENAI_HOST") == "http://inherited:8000"
      refute System.get_env("UNRELATED_VAR")
      assert Application.get_all_env(:doctrans) == previous
    end
  end

  test "missing file still applies inherited credentials to both clients", %{path: path} do
    System.put_env("OPENAI_HOST", "http://inherited:8000")
    System.put_env("OPENAI_API_KEY", "sk-inherited")

    assert :ok = EnvLoader.load(path)

    for key <- [:openai, :embedding] do
      config = Application.fetch_env!(:doctrans, key)
      assert config[:base_url] == "http://inherited:8000"
      assert config[:api_key] == "sk-inherited"
    end
  end

  test "production runtime config uses release-time credentials for both clients" do
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/doctrans_test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))
    System.put_env("OPENAI_HOST", "http://release:8000")
    System.put_env("OPENAI_API_KEY", "sk-release")

    config =
      Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :prod)

    for key <- [:openai, :embedding] do
      assert config[:doctrans][key][:base_url] == "http://release:8000"
      assert config[:doctrans][key][:api_key] == "sk-release"
    end
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
