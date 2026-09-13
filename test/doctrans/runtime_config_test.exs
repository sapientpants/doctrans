defmodule Doctrans.RuntimeConfigTest do
  # Reads `config/runtime.exs` directly: `mix test` never evaluates the storage
  # root block it defines, so the operator-facing variable is otherwise untested.
  use ExUnit.Case, async: false

  @env_keys ~w(DOCTRANS_DATA_DIR DATABASE_URL SECRET_KEY_BASE DOCTRANS_ENV_FILE)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env(%{
      "DATABASE_URL" => "ecto://unused/unused",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      # Keep the developer's own `.env` out of the configuration under test.
      "DOCTRANS_ENV_FILE" => Path.join(System.tmp_dir!(), "missing-#{Uniq.UUID.uuid7()}.env")
    })

    System.delete_env("DOCTRANS_DATA_DIR")
    :ok
  end

  defp upload_dir(env) do
    Path.expand("../../config/runtime.exs", __DIR__)
    |> Config.Reader.read!(env: env)
    |> get_in([:doctrans, :uploads, :upload_dir])
  end

  test "an absolute DOCTRANS_DATA_DIR becomes the storage root" do
    System.put_env("DOCTRANS_DATA_DIR", "/srv/doctrans-data/")

    assert upload_dir(:prod) == "/srv/doctrans-data"
  end

  test "an unset DOCTRANS_DATA_DIR leaves the storage root to the default" do
    assert upload_dir(:prod) == nil
  end

  test "a relative DOCTRANS_DATA_DIR is rejected rather than resolved against the cwd" do
    System.put_env("DOCTRANS_DATA_DIR", "data")

    assert_raise RuntimeError, ~r/must be an absolute path/, fn -> upload_dir(:prod) end
  end

  test "an empty DOCTRANS_DATA_DIR is rejected rather than silently meaning the cwd" do
    System.put_env("DOCTRANS_DATA_DIR", "")

    assert_raise RuntimeError, ~r/set but empty/, fn -> upload_dir(:prod) end
  end

  # The suite deletes directories beneath its storage root. Honouring the
  # variable in :test would let `mix test` erase the documents of an operator who
  # set it in their environment or `.env`.
  test "DOCTRANS_DATA_DIR never repoints the storage root in the test environment" do
    System.put_env("DOCTRANS_DATA_DIR", "/srv/doctrans-data")

    assert upload_dir(:test) == nil
  end

  test "an invalid DOCTRANS_DATA_DIR is ignored in the test environment" do
    System.put_env("DOCTRANS_DATA_DIR", "")

    assert upload_dir(:test) == nil
  end
end
