defmodule Doctrans.ProcessProbe do
  @moduledoc """
  Waiting on operating-system processes without asking them to report themselves.

  The tests that bound poppler, LibreOffice and `Subprocess` all need the same
  thing: the pid of a child the code under test is about to kill, and proof that
  it was reaped. The obvious way to get it — have the fake `echo $$` into a file
  the test polls for — cannot be made reliable, and Q09 measured why. A launch
  can stall inside `dyld`, before the child's first line runs, and a deadline
  SIGKILLs the whole process group while it is still there; the write then never
  happens at all, so the polled condition is not slow to become true, it becomes
  permanently unreachable. No backoff length fixes that.

  So the pid is read from the port the runtime already holds, which carries it
  from the moment of spawn, and children are read from the process table. Neither
  needs the child to have executed anything.

  These live here rather than in three copies beside the tests because the block
  is large enough that `Credo.Check.Design.DuplicatedCode` fails on triplication.
  """

  import ExUnit.Assertions

  # Polling budget shared by the `eventually*` helpers.
  @poll_attempts 100
  @poll_interval_ms 20

  @doc """
  Retries until `check` holds, then fails naming what was awaited.

  The description is required: this used to `assert check.()` at the helper's own
  line, so a wait that timed out named neither its call site nor its condition.
  """
  def eventually(check, description) do
    eventually_value(fn -> if check.(), do: :ok end, description)
  end

  @doc """
  Retries until `fetch` returns a non-`nil` value, and returns it.
  """
  def eventually_value(fetch, description, attempts \\ @poll_attempts)

  def eventually_value(_fetch, description, 0) do
    flunk("gave up after #{@poll_attempts * @poll_interval_ms}ms waiting for #{description}")
  end

  def eventually_value(fetch, description, attempts) do
    case fetch.() do
      nil ->
        Process.sleep(@poll_interval_ms)
        eventually_value(fetch, description, attempts - 1)

      value ->
        value
    end
  end

  @doc """
  The operating-system pid of the process `executable` was spawned as, asked of
  the runtime rather than of the child itself.

  The executable is matched because one owner may run several commands.
  """
  def await_os_pid(pid, executable, description) do
    eventually_value(fn -> port_os_pid(find_port(pid, executable)) end, description)
  end

  @doc """
  The first child of `parent`, once it has one.

  Only ever waited for where no deadline is running against it: a launch stalled
  before `main` has not forked anything yet, so requiring a grandchild of a run
  that is about to time out is the unsatisfiable wait this module replaced.
  """
  def await_child_pid(parent, description) do
    eventually_value(fn -> parent |> child_pids() |> List.first() end, description)
  end

  @doc """
  The trimmed contents of a pid file, once it is complete.

  Only safe where the writer is not racing a deadline — the trailing newline is
  what distinguishes a finished write from a created-but-empty file.
  """
  def await_pid_file(path, description) do
    eventually_value(
      fn ->
        with {:ok, contents} <- File.read(path),
             true <- String.ends_with?(contents, "\n") do
          String.trim(contents)
        else
          _not_yet -> nil
        end
      end,
      description
    )
  end

  @doc """
  Whether `os_pid` is absent from the process table.

  Refuses anything that is not a pid rather than reporting it gone: `/bin/ps -p
  ""` exits 1, so a pid read from a file that existed but had not been written
  yet used to make every "it was reaped" assertion pass while checking nothing.
  """
  def process_gone?(os_pid) do
    {_output, status} = System.cmd("/bin/ps", ["-p", checked_pid(os_pid)], env: [])
    status != 0
  end

  @doc """
  The children of `parent`, read from the process table.

  `ps -e -o pid=,ppid=` is POSIX and prints the same two columns on macOS and on
  the Linux CI image, so it needs no second binary beyond the `/bin/ps` already
  used here (`pgrep` is installed on both too, but its `-P` output differs).
  """
  def child_pids(parent) do
    parent = to_string(parent)
    {output, 0} = System.cmd("/bin/ps", ["-e", "-o", "pid=,ppid="], env: [])

    for line <- String.split(output, "\n", trim: true),
        [pid, ^parent] <- [String.split(line)],
        do: String.to_integer(pid)
  end

  @doc """
  The spawn port `executable` was opened on, reachable from `pid`.

  `Subprocess.run/3` opens the port in whichever process calls it: the caller
  itself, or the owner `Subprocess.supervised/1` spawn_monitors for it. Both are
  one hop away, so the caller's own links come first.
  """
  def find_port(pid, executable) do
    case linked_port(pid, executable) do
      nil -> pid |> monitored_pids() |> Enum.find_value(&linked_port(&1, executable))
      port -> port
    end
  end

  # A process monitors more than the owner `supervised/1` gives it — the code
  # server, for one — and a monitor can name a process rather than be a pid, so
  # the list is filtered rather than matched on.
  defp monitored_pids(pid) do
    case Process.info(pid, :monitors) do
      {:monitors, monitors} -> for {:process, owner} when is_pid(owner) <- monitors, do: owner
      nil -> []
    end
  end

  defp linked_port(pid, executable) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.find(links, &spawned?(&1, executable))
      nil -> nil
    end
  end

  defp spawned?(port, executable) when is_port(port) do
    :erlang.port_info(port, :name) == {:name, String.to_charlist(executable)}
  end

  defp spawned?(_other, _executable), do: false

  defp port_os_pid(nil), do: nil

  # A spawn port exists before `erl_child_setup` has reported the pid back, and
  # reports 0 until it has — measured under load, and the same guard
  # `Subprocess.port_os_pid/1` carries. 0 is "not yet", not a process.
  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 -> os_pid
      _other -> nil
    end
  end

  defp checked_pid(os_pid) when is_integer(os_pid) and os_pid > 0, do: Integer.to_string(os_pid)

  defp checked_pid(os_pid) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, ""} when pid > 0 -> os_pid
      _other -> flunk("not a process id: #{inspect(os_pid)}")
    end
  end

  defp checked_pid(os_pid), do: flunk("not a process id: #{inspect(os_pid)}")
end
