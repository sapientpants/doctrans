defmodule Doctrans.Processing.SubprocessTest do
  @moduledoc """
  Tests `Doctrans.Processing.Subprocess` directly: the deadline, the bound on
  retained output, and the credentials it keeps out of the child environment.

  `async: false` because the credential test mutates the environment of the test
  process, which every child would otherwise inherit.
  """
  use ExUnit.Case, async: false

  alias Doctrans.Processing.Subprocess

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "subprocess_test_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  defp script(dir, body) do
    path = Path.join(dir, "script_#{System.unique_integer([:positive])}")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  test "returns the exit status and output of a command that finishes", %{dir: dir} do
    command = script(dir, "#!/bin/sh\necho hello\nexit 7\n")

    assert {:ok, {"hello\n", 7}} = Subprocess.run(command, [], timeout: 10_000)
  end

  test "passes arguments through", %{dir: dir} do
    command = script(dir, "#!/bin/sh\nprintf '%s|' \"$@\"\n")

    assert {:ok, {"a|b c|", 0}} = Subprocess.run(command, ["a", "b c"], timeout: 10_000)
  end

  test "retains only the most recent output bytes", %{dir: dir} do
    command =
      script(dir, "#!/bin/sh\ni=0\nwhile [ $i -lt 500 ]; do echo abcdefghi; i=$((i+1)); done\n")

    assert {:ok, {output, 0}} = Subprocess.run(command, [], timeout: 10_000, max_output_bytes: 64)

    assert byte_size(output) == 64
    # The tail is what explains a failure, so that is the half that is kept.
    assert String.ends_with?(output, "abcdefghi\n")
  end

  test "kills a command that outruns its deadline and reports what it printed", %{dir: dir} do
    command = script(dir, "#!/bin/sh\necho starting\nexec /bin/sleep 98765\n")

    assert {:timeout, "starting\n"} = Subprocess.run(command, [], timeout: 300)
  end

  test "removes credentials from the child environment", %{dir: dir} do
    System.put_env("OPENAI_API_KEY", "sk-test-should-not-leak")
    on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

    command = script(dir, "#!/bin/sh\necho \"key=[${OPENAI_API_KEY}] path=[${PATH:+set}]\"\n")

    assert {:ok, {output, 0}} = Subprocess.run(command, [], timeout: 10_000)

    # PATH still reaches the child; only the credentials are stripped.
    assert output == "key=[] path=[set]\n"
  end

  test "applies extra environment entries", %{dir: dir} do
    command = script(dir, "#!/bin/sh\necho \"[${DOCTRANS_TEST_VAR}]\"\n")

    assert {:ok, {"[here]\n", 0}} =
             Subprocess.run(command, [], timeout: 10_000, env: [{"DOCTRANS_TEST_VAR", "here"}])
  end

  test "reports a command that cannot be started", %{dir: dir} do
    assert {:start_error, message} =
             Subprocess.run(Path.join(dir, "missing"), [], timeout: 10_000)

    assert is_binary(message)
  end

  test "supervised/1 returns the result of the work" do
    assert {:ok, :done} = Subprocess.supervised(fn -> {:ok, :done} end)
  end

  test "supervised/1 reports a process that dies without a result" do
    assert {:subprocess_owner_down, {reason, _stack}} =
             Subprocess.supervised(fn -> raise "boom" end)

    assert %RuntimeError{message: "boom"} = reason
  end
end
