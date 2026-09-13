defmodule Doctrans.Processing.Subprocess do
  @moduledoc """
  Runs external commands under a deadline, with bounded output and child cleanup.

  `System.cmd/3` waits forever, so one hung executable holds its caller — and the
  single-slot queue that caller runs in — indefinitely. `run/3` enforces a fixed
  deadline that output cannot reset, keeps only the most recent 64 KiB of
  diagnostics, and kills the child's process group when the child may still be
  running. On Unix, OTP starts port executables in their own process group
  (`erl_child_setup.c`), so the group kill also reaps grandchildren a launcher
  left behind.

  `supervised/1` runs the work in a monitored process that watches the caller, so
  a caller killed mid-run still has its child reaped and its scratch files removed.
  `run/3` recognises that caller's death only when it is called underneath
  `supervised/1`, which is where it registers the monitor it waits on.

  The child environment is an allowlist: only the variables an external converter
  legitimately needs are passed through, so a credential added to the VM's
  environment later does not silently reach LibreOffice or poppler.
  """

  require Logger

  alias Doctrans.Processing.Executable

  @default_max_output_bytes 64 * 1024
  @reap_timeout 1_000
  @caller_monitor_key {__MODULE__, :caller_monitor}

  # Only what an external document converter legitimately needs. Everything else
  # in the VM's environment — release cookies, database and mail credentials,
  # operator-set keys — is removed, so a new secret is excluded by default rather
  # than needing to be remembered.
  @inherited_env_vars ~w(
    PATH HOME TMPDIR TMP TEMP
    LANG LANGUAGE LC_ALL LC_CTYPE LC_NUMERIC TZ
    USER LOGNAME SHELL TERM
    DISPLAY XDG_RUNTIME_DIR XDG_DATA_DIRS XDG_CONFIG_HOME XDG_CACHE_HOME
    FONTCONFIG_PATH FONTCONFIG_FILE
  )

  @kill_candidates ["/bin/kill", "/usr/bin/kill"]

  @typedoc """
  The result of one bounded run.

  `{:ok, {output, exit_status}}` is a process that exited on its own, whatever its
  status; `{:timeout, output}` is one killed at the deadline; `{:start_error, message}`
  never started; `{:error, reason}` covers a port failure or a caller that exited.
  """
  @type outcome ::
          {:ok, {binary(), integer()}}
          | {:timeout, binary()}
          | {:start_error, String.t()}
          | {:error, term()}

  @doc """
  Runs `fun` in a monitored process and returns its result.

  The process monitors the caller, so `run/3` called inside `fun` sees a caller
  exit and reaps the child before unwinding. Anything that must not outlive the
  caller — a scratch profile, a temporary directory — belongs inside `fun` so its
  cleanup unwinds there too.

  Returns `{:subprocess_owner_down, reason}` if the process dies without a result,
  which is distinguishable from any `{:error, _}` `fun` itself returns.
  """
  @spec supervised((-> result)) :: result | {:subprocess_owner_down, term()} when result: var
  def supervised(fun) when is_function(fun, 0) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        # Recorded so `run/3` waits on this monitor specifically rather than on
        # any `:DOWN` that happens to be in the mailbox.
        Process.put(@caller_monitor_key, Process.monitor(caller))
        send(caller, {result_ref, fun.()})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:subprocess_owner_down, reason}
    end
  end

  @doc """
  Runs `executable` with `args` until it exits or the deadline passes.

  Call this underneath `supervised/1`. Outside it the run still works, but a
  caller that dies mid-run is not noticed until the deadline.

  ## Options

  - `:timeout` - milliseconds the command may run before its process group is
    killed (required)
  - `:max_output_bytes` - how much combined stdout/stderr to retain
    (default: #{@default_max_output_bytes}); the most recent bytes are kept, since
    the tail of a failure is what explains it
  - `:kill_on_exit` - also kill the process group after a clean exit
    (default: `false`). Needed for a launcher like `soffice` that returns while
    its children keep working; skipped otherwise, because a child that has
    already been reaped leaves its process-group id free for reuse.
  - `:env` - extra `{name, value}` pairs for the child environment, as binaries;
    a `false` value removes the variable
  """
  @spec run(String.t(), [String.t()], keyword()) :: outcome()
  def run(executable, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    kill_on_exit = Keyword.get(opts, :kill_on_exit, false)
    deadline = System.monotonic_time(:millisecond) + timeout
    env = child_env(Keyword.get(opts, :env, []))
    caller_monitor = Process.get(@caller_monitor_key) || make_ref()

    case open_port(executable, args, env) do
      {:ok, port} -> execute(port, deadline, max_output_bytes, kill_on_exit, caller_monitor)
      {:start_error, _message} = error -> error
    end
  end

  # Only the spawn itself is rescued. Wrapping the run as well would report a
  # failure in cleanup as a failure to start, hiding the real outcome.
  defp open_port(executable, args, env) do
    port =
      Port.open(
        {:spawn_executable, executable},
        # Retain port metadata even if the launcher exits before PID lookup.
        [:binary, :exit_status, :eof, :stderr_to_stdout, args: args, env: env]
      )

    {:ok, port}
  rescue
    error ->
      Logger.error("Failed to start #{executable}: #{Exception.message(error)}")

      {:start_error, Exception.message(error)}
  end

  defp execute(port, deadline, max_output_bytes, kill_on_exit, caller_monitor) do
    os_pid = port_os_pid(port)

    outcome =
      try do
        collect(port, deadline, <<>>, max_output_bytes, caller_monitor)
      catch
        kind, value ->
          reap(port, os_pid, :aborted, kill_on_exit)
          :erlang.raise(kind, value, __STACKTRACE__)
      end

    reap(port, os_pid, outcome, kill_on_exit)
    outcome
  end

  @doc """
  Turns retained command output into text safe to show and to encode.

  A byte-limited tail can begin mid-codepoint, and a tool is free to write bytes
  that are not UTF-8 at all. Either would raise when a LiveView diff carrying the
  message is encoded, so invalid bytes become replacement characters here rather
  than at the boundary that cannot recover.
  """
  @spec diagnostic(binary()) :: String.t()
  def diagnostic(output) when is_binary(output) do
    output
    |> scrub()
    |> String.trim()
  end

  # Output must never reset the deadline.
  defp collect(port, deadline, buffer, max_output_bytes, caller_monitor) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:timeout, buffer}
    else
      receive do
        {^port, {:data, data}} ->
          collect(
            port,
            deadline,
            append_output(buffer, data, max_output_bytes),
            max_output_bytes,
            caller_monitor
          )

        {^port, {:exit_status, status}} ->
          {:ok, {buffer, status}}

        {^port, :eof} ->
          # EOF and exit_status can arrive in either order. EOF alone does not
          # mean the process has exited, so continue enforcing the same deadline.
          collect(port, deadline, buffer, max_output_bytes, caller_monitor)

        {:DOWN, ^caller_monitor, :process, _caller, reason} ->
          {:error, {:caller_exited, reason}}

        {:EXIT, ^port, reason} ->
          {:error, reason}

        {^port, {:error, reason}} ->
          {:error, reason}

        {^port, _other} ->
          {:error, :port_died}
      after
        deadline - now ->
          {:timeout, buffer}
      end
    end
  end

  # Closing and draining the port always runs; the SIGKILL only runs when the
  # child may still be alive. After a clean exit `erl_child_setup` has already
  # reaped the group leader, so its process-group id is free for reuse and a kill
  # could land on an unrelated group — `:kill_on_exit` opts back in for launchers
  # whose children outlive them.
  defp reap(port, os_pid, outcome, kill_on_exit) do
    if kill_child?(outcome, kill_on_exit) and is_integer(os_pid) and os_pid > 0 do
      if kill_group(os_pid), do: await_exit(port)
    end

    close_port(port)
    drain_port(port)
  end

  defp kill_child?({:ok, {_output, _status}}, kill_on_exit), do: kill_on_exit
  defp kill_child?(_outcome, _kill_on_exit), do: true

  # Negative PIDs address the isolated Unix process group; OTP establishes the
  # group before exec (erl_child_setup.c). A kill that cannot run at all must not
  # escape: this is called from the cleanup path, where raising would both lose
  # the real outcome and skip closing the port.
  defp kill_group(os_pid) do
    case kill(["-KILL", "--", "-#{os_pid}"]) do
      {:ok, 0} ->
        true

      {:ok, _status} ->
        # The group may already be gone, or may never have been a group. Fall
        # back to the process itself before giving up on it.
        killed_directly?(os_pid)

      {:error, reason} ->
        Logger.error("Could not kill process group #{os_pid}: #{inspect(reason)}")
        false
    end
  end

  defp killed_directly?(os_pid) do
    case kill(["-KILL", "--", to_string(os_pid)]) do
      {:ok, 0} ->
        true

      {:ok, _status} ->
        false

      {:error, reason} ->
        Logger.error("Could not kill process #{os_pid}: #{inspect(reason)}")
        false
    end
  end

  # The kill binary is taken only from the fixed absolute paths above, never from
  # `PATH`: nothing about which `kill` runs should be decided by the environment
  # the VM happened to inherit.
  # sobelow_skip ["CI.System"]
  defp kill(args) do
    case Enum.find(@kill_candidates, &Executable.executable_file?/1) do
      nil ->
        {:error, :kill_not_found}

      path ->
        {_output, status} = System.cmd(path, args, stderr_to_stdout: true, env: [])
        {:ok, status}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @reap_timeout -> :ok
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp drain_port(port) do
    receive do
      {^port, _message} -> drain_port(port)
      {:EXIT, ^port, _reason} -> drain_port(port)
    after
      0 -> :ok
    end
  end

  # Appends new output, keeping only the most recent max_output_bytes.
  defp append_output(buffer, data, max_output_bytes) do
    combined = buffer <> data

    if byte_size(combined) > max_output_bytes do
      combined
      |> binary_part(byte_size(combined) - max_output_bytes, max_output_bytes)
      |> drop_partial_codepoint()
    else
      combined
    end
  end

  # A byte-boundary slice can land inside a multi-byte codepoint. UTF-8
  # continuation bytes are `0b10xxxxxx`, and no codepoint carries more than
  # three of them, so dropping them bounds the work at three bytes.
  defp drop_partial_codepoint(binary, dropped \\ 0)
  defp drop_partial_codepoint(binary, 3), do: binary
  defp drop_partial_codepoint(<<>>, _dropped), do: <<>>

  defp drop_partial_codepoint(<<byte, rest::binary>> = binary, dropped) do
    if :erlang.band(byte, 0xC0) == 0x80 do
      drop_partial_codepoint(rest, dropped + 1)
    else
      binary
    end
  end

  defp scrub(binary), do: binary |> scrub_io() |> IO.iodata_to_binary()

  defp scrub_io(<<>>), do: []
  defp scrub_io(<<char::utf8, rest::binary>>), do: [<<char::utf8>> | scrub_io(rest)]
  defp scrub_io(<<_invalid, rest::binary>>), do: ["�" | scrub_io(rest)]

  # Port environments are charlist pairs; `false` removes a variable outright.
  # `Port.open` has no way to say "start from nothing", so everything outside the
  # allowlist is removed by name.
  defp child_env(extra) do
    extra_names = MapSet.new(extra, fn {name, _value} -> name end)
    allowed = MapSet.union(MapSet.new(@inherited_env_vars), extra_names)

    removals =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(&{String.to_charlist(&1), false})

    removals ++
      Enum.map(extra, fn
        {name, false} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)
  end

  # The operating-system pid of the port's child process, used to kill a hung
  # command. Returns nil if the VM cannot report one.
  #
  # `:erlang.port_info/2` returns `:undefined` once the port has been torn down,
  # which is handled by the catch-all.
  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end
end
