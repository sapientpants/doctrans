defmodule Doctrans.Processing.ExecutableTest do
  @moduledoc """
  Tests for `Doctrans.Processing.Executable`.

  These tests run with `async: false` because they temporarily replace `$PATH`
  and the VM's working directory (both restored afterwards).
  """
  use ExUnit.Case, async: false

  alias Doctrans.Processing.Executable

  setup do
    original_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", original_path) end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "executable_test_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  defp make_tool(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "tool")
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "resolve/2 on PATH" do
    test "finds a tool in an absolute PATH directory", %{dir: dir} do
      tool = make_tool(dir)
      System.put_env("PATH", dir)

      assert {:ok, ^tool} = Executable.resolve("tool")
    end

    test "does not treat an empty PATH segment as the working directory", %{dir: dir} do
      make_tool(dir)

      for path <- ["", ":", ":/nonexistent", "/nonexistent:", "/nonexistent::/also-missing"] do
        System.put_env("PATH", path)

        assert :error = File.cd!(dir, fn -> Executable.resolve("tool") end),
               "PATH #{inspect(path)} resolved a tool from the working directory"
      end
    end

    test "does not resolve a relative PATH segment against the working directory", %{dir: dir} do
      make_tool(Path.join(dir, "bin"))
      System.put_env("PATH", "bin:.")

      assert :error = File.cd!(dir, fn -> Executable.resolve("tool") end)
    end

    test "skips an empty segment and finds the tool in a later absolute one", %{dir: dir} do
      tool = make_tool(dir)
      System.put_env("PATH", ":" <> dir)

      assert {:ok, ^tool} = File.cd!(dir, fn -> Executable.resolve("tool") end)
    end
  end
end
