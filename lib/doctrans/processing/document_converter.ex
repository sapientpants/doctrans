defmodule Doctrans.Processing.DocumentConverter do
  @moduledoc """
  Converts documents to PDF using LibreOffice with a separate profile per run.

  A monitored port owner enforces a fixed deadline and cleans up if the caller
  exits. On Unix, OTP starts port executables in their own process group; cleanup
  kills that group so launcher children cannot outlive a failed conversion.
  Captured diagnostic output is limited to 64 KiB.

  Profiles are created privately and exclusively using `/usr/bin/mktemp`,
  available on the supported macOS and Linux installations.
  """

  @behaviour Doctrans.Processing.DocumentConverterBehaviour

  require Logger

  @default_timeout 120_000
  @max_output_bytes 64 * 1024
  @search_paths [
    "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    "/usr/bin/soffice",
    "/usr/local/bin/soffice",
    "/opt/homebrew/bin/soffice"
  ]

  @impl true
  def available? do
    match?({:ok, _}, resolve_soffice_path())
  end

  @impl true
  def convert_to_pdf(source_path, output_dir) do
    if File.exists?(source_path) do
      case resolve_soffice_path() do
        {:ok, path} ->
          supervise_conversion(path, source_path, output_dir)

        {:error, _} ->
          Logger.error("LibreOffice is not installed")
          {:error, :soffice_not_found}
      end
    else
      {:error, {:source_file_not_found, [path: source_path]}}
    end
  end

  # Resolves the path of the soffice executable.
  #
  # Search order:
  #
  #   1. `:soffice_path` from `config :doctrans, :document_conversion`
  #      when it points at an existing, executable file.
  #   2. The first `soffice` found on `PATH`.
  #   3. Absolute executable entries in `:search_paths`.
  #
  # Returns `{:ok, path}` or `{:error, :soffice_not_found}`.
  @spec resolve_soffice_path() :: {:ok, String.t()} | {:error, :soffice_not_found}
  def resolve_soffice_path do
    config = Application.get_env(:doctrans, :document_conversion, [])
    configured = Keyword.get(config, :soffice_path)
    search_paths = Keyword.get(config, :search_paths, @search_paths)

    found =
      if executable_file?(configured) do
        configured
      else
        find_on_path("soffice") || Enum.find(search_paths, &absolute_executable?/1)
      end

    case found do
      nil -> {:error, :soffice_not_found}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp absolute_executable?(path),
    do: is_binary(path) and Path.type(path) == :absolute and executable_file?(path)

  # Locates `name` by searching the directories in the current `PATH`,
  # honouring whatever PATH the process environment holds at call time.
  # Returns the absolute path or `nil`.
  defp find_on_path(name) do
    path_var = System.get_env("PATH", "")

    separator =
      case :os.type() do
        {:win32, _} -> ";"
        _other -> ":"
      end

    path_var
    |> String.split(separator, trim: false)
    |> Enum.map(fn dir -> Path.join(dir, name) end)
    |> Enum.find(&executable_file?/1)
  end

  defp supervise_conversion(path, source_path, output_dir) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        Process.monitor(caller)
        result = run_conversion(path, source_path, output_dir)
        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        finalize({:error, reason}, nil, nil)
    end
  end

  # The output directory comes from the stored upload path; profile_dir is created by mktemp.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_conversion(soffice_path, source_path, output_dir) do
    File.mkdir_p!(output_dir)

    timeout = get_timeout()
    deadline = System.monotonic_time(:millisecond) + timeout
    profile_dir = create_profile_dir!()

    args = [
      "-env:UserInstallation=" <> profile_uri(profile_dir),
      "--headless",
      "--convert-to",
      "pdf",
      "--outdir",
      output_dir,
      source_path
    ]

    base_name = Path.basename(source_path, Path.extname(source_path))
    pdf_path = Path.join(output_dir, "#{base_name}.pdf")

    Logger.info("Converting #{source_path} to PDF in #{output_dir} using #{soffice_path}")

    result =
      try do
        port =
          Port.open(
            {:spawn_executable, soffice_path},
            # Retain port metadata even if the launcher exits before PID lookup.
            [:binary, :exit_status, :eof, :stderr_to_stdout, args: args]
          )

        os_pid = port_os_pid(port)

        try do
          run_port(port, deadline, <<>>)
        after
          reap_soffice(port, os_pid)
        end
      rescue
        error ->
          Logger.error("Failed to start LibreOffice: #{Exception.message(error)}")

          {:start_error, Exception.message(error)}
      after
        # Remove the throwaway profile whether the conversion succeeded,
        # failed, or was killed.
        File.rm_rf(profile_dir)
      end

    finalize(result, pdf_path, timeout)
  end

  # Output must never reset the deadline.
  defp run_port(port, deadline, buffer) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:timeout, buffer}
    else
      receive do
        {^port, {:data, data}} ->
          run_port(port, deadline, append_output(buffer, data))

        {^port, {:exit_status, status}} ->
          {:ok, {buffer, status}}

        {^port, :eof} ->
          # EOF and exit_status can arrive in either order. EOF alone does not
          # mean the process has exited, so continue enforcing the same deadline.
          run_port(port, deadline, buffer)

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

  defp finalize({:ok, {_output, 0}}, pdf_path, _timeout) do
    if File.exists?(pdf_path) do
      Logger.info("Successfully converted to #{pdf_path}")
      {:ok, pdf_path}
    else
      {:error, :converted_pdf_not_found}
    end
  end

  defp finalize({:ok, {output, exit_code}}, _pdf_path, _timeout) do
    Logger.error(
      "LibreOffice conversion failed with exit code #{exit_code}: " <>
        String.slice(output, 0, 500)
    )

    {:error, {:conversion_failed, [error: String.trim(output)]}}
  end

  defp finalize({:start_error, reason}, _pdf_path, _timeout) do
    {:error, {:conversion_start_failed, [error: String.trim(reason)]}}
  end

  defp finalize({:error, reason}, _pdf_path, _timeout) do
    {:error, {:conversion_start_failed, [error: reason]}}
  end

  defp finalize({:timeout, output}, _pdf_path, timeout) do
    Logger.error(
      "LibreOffice conversion timed out after #{timeout}ms: " <> String.slice(output, 0, 500)
    )

    {:error, :conversion_timeout}
  end

  # Keep the port open until SIGKILL is sent, then wait for OTP to reap its
  # child before closing. Negative PIDs address the isolated Unix process group.
  # OTP establishes the group before exec (erl_child_setup.c).
  defp reap_soffice(port, os_pid) do
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
      1_000 -> :ok
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

  # Appends new output, keeping only the most recent @max_output_bytes.
  defp append_output(buffer, data) do
    combined = buffer <> data

    if byte_size(combined) > @max_output_bytes do
      binary_part(combined, byte_size(combined) - @max_output_bytes, @max_output_bytes)
    else
      combined
    end
  end

  # The operating-system pid of the port's child process, used to kill a
  # hung conversion. Returns nil if the VM cannot report one.
  #
  # `:erlang.port_info/2` returns `:undefined` once the port has been
  # torn down, which is handled by the catch-all.
  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end

  # Creates a throwaway LibreOffice profile for a single conversion.
  #
  # Sharing the user's profile (LibreOffice's default) makes concurrent
  # conversions — or a conversion running while the user has LibreOffice
  # open — block on the profile lock. A per-run profile is always free.
  defp create_profile_dir! do
    template = Path.join(System.tmp_dir!(), "doctrans-soffice-XXXXXXXXXX")

    # mktemp atomically creates a fresh mode-0700 directory on macOS and Linux.
    # mkdir_p would accept an existing directory; mkdir followed by chmod would
    # leave a permissions window when the application's umask is permissive.
    case System.cmd("/usr/bin/mktemp", ["-d", template], stderr_to_stdout: true, env: []) do
      {path, 0} -> String.trim_trailing(path, "\n")
      {error, _status} -> raise "Failed to create LibreOffice profile: #{String.trim(error)}"
    end
  end

  # Encodes the profile path as a file:// URI, escaping each path segment so
  # spaces or non-ASCII characters in the temp directory do not break it.
  defp profile_uri(profile_dir) do
    encoded =
      profile_dir
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))

    "file://" <> encoded
  end

  # Returns the configured timeout in milliseconds.
  defp get_timeout do
    config = Application.get_env(:doctrans, :document_conversion, [])
    Keyword.get(config, :timeout, @default_timeout)
  end

  # Returns true when `path` points at an existing, executable regular file.
  defp executable_file?(path) do
    is_binary(path) and executable_stats?(path)
  end

  defp executable_stats?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> :erlang.band(mode, 0o111) != 0
      _other -> false
    end
  end
end
