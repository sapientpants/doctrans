defmodule Doctrans.Processing.ExecutableTest do
  @moduledoc """
  Tests for `Doctrans.Processing.Executable`.

  These tests run with `async: false` because they temporarily replace `$PATH`
  and the VM's working directory (both restored afterwards).
  """
  use Doctrans.EnvCase, async: false

  alias Doctrans.Processing.Executable

  setup do
    previous = System.get_env("PATH")

    on_exit(fn ->
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end)
  end

  defp make_tool(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "tool")
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "resolve/2 on PATH" do
    @describetag :tmp_dir

    test "finds a tool in an absolute PATH directory", %{tmp_dir: dir} do
      tool = make_tool(dir)
      System.put_env("PATH", dir)

      assert {:ok, ^tool} = Executable.resolve("tool")
    end

    for path_value <- ["", ":", ":/nonexistent", "/nonexistent:", "/nonexistent::/also-missing"] do
      test "does not treat an empty segment of PATH #{inspect(path_value)} as the working directory",
           %{tmp_dir: dir} do
        make_tool(dir)
        System.put_env("PATH", unquote(path_value))

        assert :error = File.cd!(dir, fn -> Executable.resolve("tool") end)
      end
    end

    test "does not resolve a relative PATH segment against the working directory", %{
      tmp_dir: dir
    } do
      make_tool(Path.join(dir, "bin"))
      System.put_env("PATH", "bin:.")

      assert :error = File.cd!(dir, fn -> Executable.resolve("tool") end)
    end

    test "skips an empty segment and finds the tool in a later absolute one", %{tmp_dir: dir} do
      tool = make_tool(dir)
      System.put_env("PATH", ":" <> dir)

      assert {:ok, ^tool} = File.cd!(dir, fn -> Executable.resolve("tool") end)
    end
  end
end
