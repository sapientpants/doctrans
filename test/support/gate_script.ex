defmodule Doctrans.GateScript do
  @moduledoc """
  Runs one of the `scripts/check_*.exs` pre-commit gates as a subprocess.

  The gates are plain `elixir` scripts that read the working directory and exit
  non-zero on a problem, and that exit code is the whole of their contract with
  `.pre-commit-config.yaml`. Loading them into the test VM would need every one
  to grow a guard and an injectable root; running the real command against a
  fixture tree tests what the hook actually runs, exit status included.
  """

  @scripts_dir Path.expand("../../scripts", __DIR__)

  @doc """
  Runs `scripts/<script>` with `args` from `dir` and returns `{output, exit_status}`.

  Standard error is folded into the output so an abort message is as assertable
  as a report.
  """
  @spec run(String.t(), [String.t()], Path.t()) :: {String.t(), non_neg_integer()}
  def run(script, args, dir) do
    System.cmd("elixir", [Path.join(@scripts_dir, script) | args],
      cd: dir,
      stderr_to_stdout: true,
      env: scrubbed_env()
    )
  end

  # System.cmd inherits the VM's environment even with `env: []`. Keep only what
  # a toolchain needs to start; credentials must not reach a subprocess that is
  # only here to read fixture files.
  defp scrubbed_env do
    System.get_env()
    |> Map.keys()
    |> Enum.reject(&(&1 in ~w(PATH HOME TMPDIR TMP TEMP LANG LC_ALL TZ SystemRoot WINDIR)))
    |> Enum.map(&{&1, nil})
  end

  @doc "Writes `contents` to `path` beneath `dir`, creating the directories on the way."
  @spec write(Path.t(), Path.t(), iodata()) :: :ok
  def write(dir, path, contents) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end
end
