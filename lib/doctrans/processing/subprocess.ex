defmodule Doctrans.Processing.Subprocess do
  @moduledoc """
  Runs external commands under a deadline, with bounded output and child cleanup.

  `System.cmd/3` waits forever, so one hung executable holds its caller — and the
  single-slot queue that caller runs in — indefinitely. `run/3` enforces a fixed
  deadline that output cannot reset, keeps only the most recent
  `#{64 * 1024} bytes` of diagnostics, and kills the child's process group on every
  exit path. On Unix, OTP starts port executables in their own process group
  (`erl_child_setup.c`), so the group kill also reaps grandchildren a launcher
  left behind.

  `supervised/1` runs the work in a monitored process that watches the caller, so
  a caller killed mid-run still has its child reaped and its scratch files removed.

  Credentials are removed from the child environment: neither LibreOffice nor
  poppler needs them, and a process that never sees a key cannot leak one.
  """

  require Logger

  @default_max_output_bytes 64 * 1024
  @reap_timeout 1_000
  @secret_env_vars ~w(OPENAI_API_KEY DATABASE_URL SECRET_KEY_BASE)

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
        Process.monitor(caller)
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

  ## Options

  - `:timeout` - milliseconds the command may run before its process group is
    killed (required)
  - `:max_output_bytes` - how much combined stdout/stderr to retain
    (default: #{@default_max_output_bytes}); the most recent bytes are kept, since
    the tail of a failure is what explains it
  - `:env` - extra `{name, value}` pairs for the child environment, as binaries;
    a `false` value removes the variable
  """
  @spec run(String.t(), [String.t()], keyword()) :: outcome()
  def run(executable, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    deadline = System.monotonic_time(:millisecond) + timeout
    env = child_env(Keyword.get(opts, :env, []))

    try do
      port =
        Port.open(
          {:spawn_executable, executable},
          # Retain port metadata even if the launcher exits before PID lookup.
          [:binary, :exit_status, :eof, :stderr_to_stdout, args: args, env: env]
        )

      os_pid = port_os_pid(port)

      try do
        collect(port, deadline, <<>>, max_output_bytes)
      after
        reap(port, os_pid)
      end
    rescue
      error ->
        Logger.error("Failed to start #{executable}: #{Exception.message(error)}")

        {:start_error, Exception.message(error)}
    end
  end

  # Output must never reset the deadline.
  defp collect(port, deadline, buffer, max_output_bytes) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:timeout, buffer}
    else
      receive do
        {^port, {:data, data}} ->
          collect(port, deadline, append_output(buffer, data, max_output_bytes), max_output_bytes)

        {^port, {:exit_status, status}} ->
          {:ok, {buffer, status}}

        {^port, :eof} ->
          # EOF and exit_status can arrive in either order. EOF alone does not
          # mean the process has exited, so continue enforcing the same deadline.
          collect(port, deadline, buffer, max_output_bytes)

        {:DOWN, _monitor, :process, _caller, reason} ->
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

  # Keep the port open until SIGKILL is sent, then wait for OTP to reap its
  # child before closing. Negative PIDs address the isolated Unix process group.
  # OTP establishes the group before exec (erl_child_setup.c).
  defp reap(port, os_pid) do
    if is_integer(os_pid) and os_pid > 0 do
      case System.cmd("/bin/kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true, env: []) do
        {_output, 0} -> await_exit(port)
        {_output, _status} -> :ok
      end
    end

    close_port(port)
    drain_port(port)
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
      binary_part(combined, byte_size(combined) - max_output_bytes, max_output_bytes)
    else
      combined
    end
  end

  # Port environments are charlist pairs; `false` removes a variable outright.
  defp child_env(extra) do
    Enum.map(@secret_env_vars, &{String.to_charlist(&1), false}) ++
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
