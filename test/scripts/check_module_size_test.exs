defmodule Scripts.CheckModuleSizeTest do
  @moduledoc """
  Smoke-tests the pre-commit gate in `scripts/check_module_size.exs`.

  The limit is passed by the hook and has no default, so the cases pass their
  own; the regressions worth pinning are the ones that produced a pass that
  verified nothing -- an empty match, a silently dropped `.exs` -- and the
  off-by-one that once measured every file a line longer than `wc -l`.
  """
  use ExUnit.Case, async: true

  import Doctrans.GateScript, only: [run: 3, write: 3]

  @moduletag :tmp_dir
  @script "check_module_size.exs"

  test "every module within the limit passes", %{tmp_dir: dir} do
    write(dir, "lib/small.ex", lines(3))

    assert {output, 0} = run(@script, ["--max-lines", "5"], dir)
    assert output =~ "All 1 modules are within the 5 line limit"
    assert output =~ "lib/small.ex at 3"
  end

  test "a module over the limit fails and is named with its overage", %{tmp_dir: dir} do
    write(dir, "lib/small.ex", lines(3))
    write(dir, "lib/big.ex", lines(7))

    assert {output, 1} = run(@script, ["--max-lines", "5"], dir)
    assert output =~ "Module size violations found"
    assert output =~ "lib/big.ex"
    assert output =~ "Lines: 7 (2 over the 5 line limit)"
    refute output =~ "lib/small.ex"
  end

  test "a file is measured as wc -l measures it, so a file exactly at the limit passes",
       %{tmp_dir: dir} do
    write(dir, "lib/exact.ex", lines(5))

    assert {output, 0} = run(@script, ["--max-lines", "5"], dir)
    assert output =~ "lib/exact.ex at 5"
  end

  test "--max-lines is required", %{tmp_dir: dir} do
    write(dir, "lib/small.ex", lines(3))

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "--max-lines is required"
  end

  test "a non-positive limit is refused", %{tmp_dir: dir} do
    write(dir, "lib/small.ex", lines(3))

    assert {output, 1} = run(@script, ["--max-lines", "0"], dir)
    assert output =~ "--max-lines must be positive"
  end

  test "a path matching no .ex file is a failure, not a pass", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))

    assert {output, 1} = run(@script, ["--max-lines", "5"], dir)
    assert output =~ "no .ex files matched"
  end

  test "an explicitly named .exs file is an error rather than a silent pass",
       %{tmp_dir: dir} do
    write(dir, "lib/script.exs", lines(3))

    assert {output, 1} = run(@script, ["--max-lines", "5", "lib/script.exs"], dir)
    assert output =~ "lib/script.exs is not a .ex file"
  end

  test "an explicitly named directory scopes the check", %{tmp_dir: dir} do
    write(dir, "lib/big.ex", lines(7))
    write(dir, "other/small.ex", lines(3))

    assert {_output, 0} = run(@script, ["--max-lines", "5", "other"], dir)
    assert {_output, 1} = run(@script, ["--max-lines", "5", "lib"], dir)
  end

  test "an unrecognised option is refused", %{tmp_dir: dir} do
    write(dir, "lib/small.ex", lines(3))

    assert {output, 1} = run(@script, ["--max-lines", "5", "--bogus"], dir)
    assert output =~ "unrecognised option --bogus"
  end

  defp lines(count), do: Enum.map_join(1..count, "", &"# line #{&1}\n")
end
