defmodule Doctrans.Processing.SubprocessTest do
  @moduledoc """
  Tests `Doctrans.Processing.Subprocess` directly: the deadline, the bound on
  retained output, and the credentials it keeps out of the child environment.

  `async: false` because the credential test mutates the environment of the test
  process, which every child would otherwise inherit.
  """
  use ExUnit.Case, async: false

  import Doctrans.ProcessProbe

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

    # 2_000 rather than the 300 this ran at. The command has to be seen alive
    # before the deadline kills it, and seeing it costs a `/bin/ps` — itself a
    # process launch, and a launch can stall for most of a second before its
    # first instruction runs.
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Subprocess.run(command, [], timeout: 2_000) end)

    # Read from the port, not from a pid file: the deadline SIGKILLs the process
    # group, and a shell still starting up when that lands never runs the line
    # that would have recorded its pid.
    os_pid = await_os_pid(task.pid, command, "the command to be spawned")

    # The vacuity guard: "the command is gone" is true of a command that never
    # ran, so it is observed alive before it is awaited gone.
    refute process_gone?(os_pid), "command #{os_pid} was never running"

    assert {:timeout, "starting\n"} = Task.await(task, 30_000)
    assert System.monotonic_time(:millisecond) - started >= 2_000

    # The deadline is only half the contract: the operating-system process has to
    # be gone too, or the slot it occupies is never freed.
    eventually(fn -> process_gone?(os_pid) end, "command #{os_pid} to be reaped")
  end

  test "the reap check refuses a pid it cannot check" do
    # `/bin/ps -p ""` exits 1, so a pid read from a file that existed but was
    # still empty used to read as "that process is gone" — which made both reap
    # assertions above pass while checking nothing at all.
    assert_raise ExUnit.AssertionError, fn -> process_gone?("") end
    assert_raise ExUnit.AssertionError, fn -> process_gone?(0) end
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

    grandchild = await_pid_file(pid_file, "the launcher to record its grandchild's pid")
    eventually(fn -> process_gone?(grandchild) end, "grandchild #{grandchild} to be reaped")
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

    # The message is what the caller logs and stores, so it has to say why the
    # spawn failed rather than merely be a string: `Port.open/2` raises
    # `:enoent` for an executable that is not there.
    assert message =~ "enoent"
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

  test "supervised/1 reaps the child and its own children when the caller dies", %{dir: dir} do
    # The group kill is asserted here rather than on the deadline path above,
    # because whether a grandchild exists at all is not something a timing-out
    # run can promise: the command may still be starting up when its deadline
    # kills it. Nothing races the observation under a 60-second deadline, and
    # caller death reaps through the same `kill_group/1` call a deadline uses.
    command =
      script(dir, """
      #!/bin/sh
      /bin/sleep 98765 &
      wait
      """)

    caller =
      spawn(fn ->
        Subprocess.supervised(fn -> Subprocess.run(command, [], timeout: 60_000) end)
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)

    os_pid = await_os_pid(caller, command, "the command to be spawned")
    child = await_child_pid(os_pid, "the command to fork its child")

    refute process_gone?(os_pid), "command #{os_pid} was never running"
    refute process_gone?(child), "command child #{child} was never running"

    Process.exit(caller, :kill)

    # The owner monitors the caller, so the child is killed rather than left to
    # run out a 60-second deadline nobody is waiting on.
    eventually(fn -> process_gone?(os_pid) end, "command #{os_pid} to be reaped")
    eventually(fn -> process_gone?(child) end, "command child #{child} to be reaped")
  end
end
