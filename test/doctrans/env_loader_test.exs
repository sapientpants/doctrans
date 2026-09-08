defmodule Doctrans.EnvLoaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Doctrans.EnvLoader

  @env_keys ~w(OPENAI_HOST OPENAI_API_KEY UNRELATED_VAR DATABASE_URL SECRET_KEY_BASE DOCTRANS_ENV_FILE)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    for key <- @env_keys, do: System.delete_env(key)

    path =
      Path.join(System.tmp_dir!(), "env_loader_test_#{System.unique_integer([:positive])}.env")

    System.put_env("DOCTRANS_ENV_FILE", path)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      File.rm(path)
    end)

    %{path: path}
  end

  test "loads file defaults using the explicit environment file path", %{path: path} do
    File.write!(path, """
      # a comment

    OPENAI_HOST=http://from-file:1234
    OPENAI_API_KEY=sk-from-file
    UNRELATED_VAR=unrelated
    """)

    assert :ok = EnvLoader.load()
    assert System.get_env("OPENAI_HOST") == "http://from-file:1234"
    assert System.get_env("OPENAI_API_KEY") == "sk-from-file"
    assert System.get_env("UNRELATED_VAR") == "unrelated"
  end

  test "inherited settings win and conflicts never reveal values", %{path: path} do
    System.put_env("OPENAI_HOST", "http://inherited:9999")
    System.put_env("OPENAI_API_KEY", "sk-inherited-secret")
    File.write!(path, "OPENAI_HOST=http://file:8000\nOPENAI_API_KEY=sk-file-secret\n")

    log = capture_log(fn -> assert :ok = EnvLoader.load(path) end)

    assert System.get_env("OPENAI_HOST") == "http://inherited:9999"
    assert System.get_env("OPENAI_API_KEY") == "sk-inherited-secret"
    assert log =~ "Inherited OPENAI_HOST overrides"
    assert log =~ "Inherited OPENAI_API_KEY overrides"
    refute log =~ "sk-inherited-secret"
    refute log =~ "sk-file-secret"
    refute log =~ "http://inherited"
    refute log =~ "http://file"
  end

  test "equal API settings do not warn", %{path: path} do
    System.put_env("OPENAI_API_KEY", "sk-same")
    File.write!(path, "OPENAI_API_KEY=sk-same\n")
    assert capture_log(fn -> EnvLoader.load(path) end) == ""
  end

  test "explicitly empty inherited values win", %{path: path} do
    System.put_env("OPENAI_API_KEY", "")
    File.write!(path, "OPENAI_API_KEY=sk-file\n")
    capture_log(fn -> assert :ok = EnvLoader.load(path) end)
    assert System.get_env("OPENAI_API_KEY") == ""
  end

  test "empty file values do not replace inherited credentials", %{path: path} do
    System.put_env("OPENAI_API_KEY", "sk-inherited")
    File.write!(path, "OPENAI_API_KEY=\n")
    capture_log(fn -> assert :ok = EnvLoader.load(path) end)
    assert System.get_env("OPENAI_API_KEY") == "sk-inherited"
  end

  test "variables absent from the file retain inherited values", %{path: path} do
    System.put_env("OPENAI_HOST", "http://inherited:8000")
    File.write!(path, "OPENAI_API_KEY=sk-file\n")
    assert :ok = EnvLoader.load(path)
    assert System.get_env("OPENAI_HOST") == "http://inherited:8000"
  end

  for env <- [:dev, :test, :prod] do
    test "#{env} runtime settings use file defaults for both clients and inherited overrides",
         %{path: path} do
      System.put_env("OPENAI_API_KEY", "sk-inherited")

      File.write!(path, """
      OPENAI_HOST=http://file:8000
      OPENAI_API_KEY=sk-file
      DATABASE_URL=ecto://postgres:postgres@localhost/doctrans_test
      SECRET_KEY_BASE=#{String.duplicate("a", 64)}
      """)

      capture_log(fn ->
        config =
          Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__),
            env: unquote(env)
          )

        for key <- [:openai, :embedding] do
          assert config[:doctrans][key][:base_url] == "http://file:8000"
          assert config[:doctrans][key][:api_key] == "sk-inherited"
        end

        if unquote(env) == :prod do
          assert config[:doctrans][Doctrans.Repo][:url] ==
                   "ecto://postgres:postgres@localhost/doctrans_test"

          assert config[:doctrans][DoctransWeb.Endpoint][:secret_key_base] ==
                   String.duplicate("a", 64)
        end
      end)
    end
  end

  test "a key-only line sets an empty value", %{path: path} do
    File.write!(path, "OPENAI_API_KEY\n")
    assert :ok = EnvLoader.load(path)
    assert System.get_env("OPENAI_API_KEY") == ""
  end

  test "a missing file is optional", %{path: path} do
    assert :ok = EnvLoader.load(path)
    refute System.get_env("OPENAI_API_KEY")
  end

  test "unreadable files report an error instead of silently ignoring configuration" do
    assert_raise File.Error, fn -> EnvLoader.load(System.tmp_dir!()) end
  end
end
