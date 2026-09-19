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
    pid_file = Path.join(dir, "pid")

    command =
      script(dir, """
      #!/bin/sh
      echo starting
      echo $$ > "#{pid_file}"
      exec /bin/sleep 98765
      """)

    assert {:timeout, "starting\n"} = Subprocess.run(command, [], timeout: 300)

    # The deadline is only half the contract: the operating-system process has to
    # be gone too, or the slot it occupies is never freed.
    eventually(fn -> File.exists?(pid_file) end)
    os_pid = pid_file |> File.read!() |> String.trim()
    eventually(fn -> process_gone?(os_pid) end)
  end

  test "keeps a byte-limited tail valid to encode", %{dir: dir} do
    # Three-byte codepoints, so a 64-byte window cannot land on a boundary.
    command =
      script(
        dir,
        "#!/bin/sh\ni=0\nwhile [ $i -lt 200 ]; do printf '\u4f60\u597d'; i=$((i+1)); done\n"
      )

    assert {:ok, {output, 0}} = Subprocess.run(command, [], timeout: 10_000, max_output_bytes: 64)

    assert byte_size(output) <= 64
    # An invalid binary here would raise when a LiveView diff carrying it is encoded.
    assert String.valid?(output)
  end

  test "replaces bytes that are not text at all", %{dir: dir} do
    command = script(dir, "#!/bin/sh\nprintf 'before\\300\\300after'\n")

    assert {:ok, {output, 0}} = Subprocess.run(command, [], timeout: 10_000)

    diagnostic = Subprocess.diagnostic(output)
    assert String.valid?(diagnostic)
    assert diagnostic =~ "before"
    assert diagnostic =~ "after"
  end

  test "removes an environment variable on request", %{dir: dir} do
    System.put_env("DOCTRANS_TEST_REMOVED", "present")
    on_exit(fn -> System.delete_env("DOCTRANS_TEST_REMOVED") end)

    command = script(dir, "#!/bin/sh\necho \"[${DOCTRANS_TEST_REMOVED}]\"\n")

    assert {:ok, {"[]\n", 0}} =
             Subprocess.run(command, [], timeout: 10_000, env: [{"DOCTRANS_TEST_REMOVED", false}])
  end

  test "passes only allowlisted variables to the child", %{dir: dir} do
    System.put_env("DOCTRANS_TEST_SECRET", "must-not-leak")
    on_exit(fn -> System.delete_env("DOCTRANS_TEST_SECRET") end)

    command = script(dir, "#!/bin/sh\necho \"[${DOCTRANS_TEST_SECRET}]\"\n")

    # The allowlist is why this holds: the variable is not on any denylist, it is
    # simply not one of the names a converter is given.
    assert {:ok, {"[]\n", 0}} = Subprocess.run(command, [], timeout: 10_000)
  end

  test "a clean exit does not signal a process group that may have been reused", %{dir: dir} do
    # A command that exits on its own has already been reaped, so its group id is
    # free; killing it anyway is what :kill_on_exit opts back into.
    command = script(dir, "#!/bin/sh\nexit 0\n")

    assert {:ok, {"", 0}} = Subprocess.run(command, [], timeout: 10_000)
    assert {:ok, {"", 0}} = Subprocess.run(command, [], timeout: 10_000, kill_on_exit: true)
  end

  test "kill_on_exit reaps children a launcher leaves behind", %{dir: dir} do
    pid_file = Path.join(dir, "grandchild")

    launcher =
      script(dir, """
      #!/bin/sh
      # Redirected the way a daemonising launcher detaches: while a descendant
      # still holds the output pipe, the port reports no exit status at all, so
      # this is the only shape in which the clean-exit path is even reached.
      /bin/sleep 98765 >/dev/null 2>&1 &
      echo $! > "#{pid_file}"
      exit 0
      """)

    assert {:ok, {"", 0}} = Subprocess.run(launcher, [], timeout: 10_000, kill_on_exit: true)

    eventually(fn -> File.exists?(pid_file) end)
    grandchild = pid_file |> File.read!() |> String.trim()
    eventually(fn -> process_gone?(grandchild) end)
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

  test "run/3 ignores a :DOWN that is not its caller's", %{dir: dir} do
    # An unrelated monitor firing mid-run must neither abort the run nor be
    # swallowed: outside `supervised/1` there is no caller monitor to confuse it
    # with, and the message has to still be there afterwards.
    {unrelated, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^unrelated, :normal}
    send(self(), {:DOWN, monitor, :process, unrelated, :normal})

    command = script(dir, "#!/bin/sh\necho fine\n")

    assert {:ok, {"fine\n", 0}} = Subprocess.run(command, [], timeout: 10_000)
    assert_received {:DOWN, ^monitor, :process, ^unrelated, :normal}
  end

  test "supervised/1 reaps the child when the caller dies", %{dir: dir} do
    pid_file = Path.join(dir, "caller_child")

    command =
      script(dir, """
      #!/bin/sh
      echo $$ > "#{pid_file}"
      exec /bin/sleep 98765
      """)

    caller =
      spawn(fn ->
        Subprocess.supervised(fn -> Subprocess.run(command, [], timeout: 60_000) end)
      end)

    eventually(fn -> File.exists?(pid_file) end)
    os_pid = pid_file |> File.read!() |> String.trim()

    Process.exit(caller, :kill)

    # The owner monitors the caller, so the child is killed rather than left to
    # run out a 60-second deadline nobody is waiting on.
    eventually(fn -> process_gone?(os_pid) end)
  end

  defp process_gone?(os_pid) do
    {_output, status} = System.cmd("/bin/ps", ["-p", os_pid], env: [])
    status != 0
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
