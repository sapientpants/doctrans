defmodule Doctrans.Processing.DocumentConverterTest do
  @moduledoc """
  Tests for `Doctrans.Processing.DocumentConverter`.

  These tests run with `async: false` because they temporarily mutate the
  `:doctrans` application environment and `$PATH` (restored afterwards).

  Fakes are spawned through `:erlang.open_port/2`'s `:spawn_executable`,
  which execs the file directly, so every fake must carry a `#!/bin/sh`
  shebang (a shebang-less script would fail with ENOEXEC, port exit 8).
  """
  use ExUnit.Case, async: false

  alias Doctrans.Processing.DocumentConverter

  setup do
    original_config = Application.get_env(:doctrans, :document_conversion, [])
    original_path = System.get_env("PATH")

    on_exit(fn ->
      Application.put_env(:doctrans, :document_conversion, original_config)
      System.put_env("PATH", original_path)
    end)

    %{original_path: original_path}
  end

  defp put_config(config) do
    Application.put_env(:doctrans, :document_conversion, config)
  end

  # Temporarily replaces $PATH so find_on_path/1 only sees what the test
  # sets up. Restored by the on_exit callback in setup/1.
  defp swap_path(path) do
    System.put_env("PATH", path)
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "converter_test_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Creates an executable shell script named `soffice` in `dir` containing
  # `body`. The body must start with a shebang: the converter execs the
  # file directly via a port, which does not tolerate shebang-less scripts.
  defp make_fake_soffice(dir, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "soffice")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  # Writes a plain-text file that LibreOffice (or a fake) can "convert".
  defp make_source(dir, filename) do
    path = Path.join(dir, filename)
    File.write!(path, "hello world")
    path
  end

  describe "resolve_soffice_path/0" do
    test "prefers the configured :soffice_path" do
      fake = make_fake_soffice(tmp_dir(), "#!/bin/sh\n")
      put_config(soffice_path: fake)

      assert {:ok, ^fake} = DocumentConverter.resolve_soffice_path()
    end

    test "ignores a configured path that is not an executable" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      not_executable = Path.join(dir, "soffice")
      File.write!(not_executable, "#!/bin/sh\n")
      put_config(soffice_path: not_executable, search_paths: [])
      swap_path("")

      assert {:error, :soffice_not_found} = DocumentConverter.resolve_soffice_path()
    end

    test "falls back to a soffice found on $PATH" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      fake = make_fake_soffice(dir, "#!/bin/sh\n")
      put_config(search_paths: [])
      swap_path(dir)

      assert {:ok, ^fake} = DocumentConverter.resolve_soffice_path()
    end

    test "falls back to configured search paths when not on $PATH" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      fake = make_fake_soffice(dir, "#!/bin/sh\n")
      put_config(search_paths: ["/nonexistent/soffice", fake])
      swap_path("")

      assert {:ok, ^fake} = DocumentConverter.resolve_soffice_path()
    end

    test "returns :soffice_not_found when nothing exists" do
      put_config(search_paths: [])
      swap_path("")

      assert {:error, :soffice_not_found} = DocumentConverter.resolve_soffice_path()
    end
  end

  describe "available?/0" do
    test "is true when an executable can be resolved" do
      fake = make_fake_soffice(tmp_dir(), "#!/bin/sh\n")
      put_config(soffice_path: fake)

      assert DocumentConverter.available?()
    end

    test "is false when no executable can be found" do
      put_config(search_paths: [])
      swap_path("")

      refute DocumentConverter.available?()
    end
  end

  describe "convert_to_pdf/2" do
    test "returns an error for a non-existent source file" do
      output_dir = tmp_dir()
      on_exit(fn -> File.rm_rf(output_dir) end)

      result = DocumentConverter.convert_to_pdf("/nonexistent/file.docx", output_dir)

      assert {:error, message} = result
      assert message =~ "not found"
    end

    test "fails fast with a clear error when LibreOffice is not installed" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)
      source = make_source(dir, "test.docx")

      put_config(search_paths: [])
      swap_path("")

      result = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))

      assert {:error, message} = result
      assert message =~ "LibreOffice is not installed"
    end

    test "returns {:ok, pdf_path} when the conversion succeeds" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      fake = make_fake_soffice(dir, fake_soffice_body())
      put_config(soffice_path: fake, timeout: 10_000)

      source = make_source(dir, "book.docx")
      output_dir = Path.join(dir, "out")
      result = DocumentConverter.convert_to_pdf(source, output_dir)

      assert {:ok, pdf_path} = result
      assert pdf_path == Path.join(output_dir, "book.pdf")
      assert File.exists?(pdf_path)
    end

    test "surfaces soffice error output on a non-zero exit" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      fake = make_fake_soffice(dir, "#!/bin/sh\necho \"boom: bad file\" 1>&2\nexit 3\n")
      put_config(soffice_path: fake, timeout: 10_000)

      source = make_source(dir, "book.docx")
      result = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))

      assert {:error, message} = result
      assert message =~ "boom: bad file"
    end

    test "runs with an isolated profile that is removed afterwards" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      argv_file = Path.join(dir, "argv.txt")

      fake =
        make_fake_soffice(dir, """
        #!/bin/sh
        { for a in "$@"; do printf '%s\\n' "$a"; done } > #{argv_file}
        #{fake_soffice_body()}
        """)

      put_config(soffice_path: fake, timeout: 10_000)

      source = make_source(dir, "book.docx")
      output_dir = Path.join(dir, "out")
      assert {:ok, _} = DocumentConverter.convert_to_pdf(source, output_dir)

      args = File.read!(argv_file) |> String.split("\n")
      profile_arg = Enum.find(args, &String.starts_with?(&1, "-env:UserInstallation="))
      assert profile_arg != nil

      profile_path =
        profile_arg
        |> String.replace_prefix("-env:UserInstallation=file://", "")
        |> URI.decode()

      # The throwaway profile must be gone once the conversion finished.
      refute File.exists?(profile_path)
    end

    test "times out, kills the hung soffice process, and reports the timeout" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      pid_file = Path.join(dir, "pid.txt")

      # A launcher waiting on a child models LibreOffice's process tree.
      fake =
        make_fake_soffice(dir, """
        #!/bin/sh
        echo $$ > #{pid_file}
        /bin/sleep 98765 &
        echo $! > #{pid_file}.child
        wait
        """)

      put_config(soffice_path: fake, timeout: 800)

      source = make_source(dir, "book.docx")
      output_dir = Path.join(dir, "out")

      start = System.monotonic_time(:millisecond)
      result = DocumentConverter.convert_to_pdf(source, output_dir)
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, message} = result
      assert message =~ "timed out"
      assert elapsed >= 800

      pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()

      # Give the kill a moment to take effect, then verify the process is gone.
      Process.sleep(300)

      {_out, status} = System.cmd("ps", ["-p", Integer.to_string(pid)], env: [])
      assert status != 0, "soffice process #{pid} should have been killed"

      child_pid = File.read!(pid_file <> ".child") |> String.trim()
      {_out, status} = System.cmd("ps", ["-p", child_pid], env: [])
      assert status != 0, "LibreOffice child #{child_pid} should have been reaped"
      refute_receive {_port, {:exit_status, _}}
    end
  end

  test "a partial PDF and continuous output do not turn a timeout into success" do
    dir = tmp_dir()
    fake = make_fake_soffice(dir, fake_soffice_body() <> "while :; do echo still-running; done\n")
    put_config(soffice_path: fake, timeout: 300)
    source = make_source(dir, "book.docx")
    started = System.monotonic_time(:millisecond)

    assert {:error, message} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
    assert message =~ "timed out"
    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "cleans up the process and profile when the caller is killed" do
    dir = tmp_dir()
    pid_file = Path.join(dir, "pid")
    profile_file = Path.join(dir, "profile")

    fake =
      make_fake_soffice(dir, """
      #!/bin/sh
      echo "${1#-env:UserInstallation=file://}" > "#{profile_file}"
      echo $$ > "#{pid_file}"
      exec /bin/sleep 98765
      """)

    put_config(soffice_path: fake, timeout: 10_000)
    source = make_source(dir, "book.docx")
    caller = spawn(fn -> DocumentConverter.convert_to_pdf(source, Path.join(dir, "out")) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    eventually(fn -> File.exists?(pid_file) and File.read!(pid_file) != "" end)
    pid = File.read!(pid_file) |> String.trim()
    profile = File.read!(profile_file) |> String.trim() |> URI.decode()
    assert File.dir?(profile)
    assert Bitwise.band(File.stat!(profile).mode, 0o777) == 0o700
    Process.exit(caller, :kill)

    eventually(fn ->
      {_output, status} = System.cmd("ps", ["-p", pid], env: [])
      status != 0 and not File.exists?(profile)
    end)
  end

  test "retains the launcher PID after exit and kills its surviving child" do
    dir = tmp_dir()
    ready = Path.join(dir, "ready")
    release = Path.join(dir, "release")

    fake =
      make_fake_soffice(dir, """
      #!/bin/sh
      /bin/sleep 30 </dev/null >/dev/null 2>&1 &
      echo $! > "#{dir}/child"
      echo $$ > "#{ready}"
      while [ ! -f "#{release}" ]; do /bin/sleep 0.02; done
      exit 3
      """)

    put_config(soffice_path: fake, timeout: 10_000)
    source = make_source(dir, "book.docx")
    task = Task.async(fn -> DocumentConverter.convert_to_pdf(source, Path.join(dir, "out")) end)
    eventually(fn -> File.exists?(ready) and File.read!(ready) != "" end)
    launcher = File.read!(ready) |> String.trim() |> String.to_integer()
    child = File.read!(Path.join(dir, "child")) |> String.trim()
    {:monitors, [{:process, owner}]} = Process.info(task.pid, :monitors)
    {:links, links} = Process.info(owner, :links)
    port = Enum.find(links, &is_port/1)

    # Hold the owner until the launcher has exited. PID lookup must still work
    # at this point, even if the owner was descheduled immediately after open.
    :erlang.suspend_process(owner)

    try do
      File.touch!(release)
      eventually(fn -> process_gone?(Integer.to_string(launcher)) end)
      refute process_gone?(child)
      assert Port.info(port, :os_pid) == {:os_pid, launcher}
    after
      :erlang.resume_process(owner)
    end

    assert {:error, _message} = Task.await(task, 5_000)
    eventually(fn -> process_gone?(child) end)
  end

  test "EOF without process exit still times out and cleans up" do
    dir = tmp_dir()
    fake = make_fake_soffice(dir, "#!/bin/sh\nexec 1>&- 2>&-\nexec /bin/sleep 30\n")
    put_config(soffice_path: fake, timeout: 800)
    source = make_source(dir, "book.docx")

    assert {:error, message} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
    assert message =~ "timed out"
  end

  test "creates fresh profiles without reusing an existing template path" do
    dir = tmp_dir()
    original_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", dir)

    on_exit(fn ->
      if original_tmpdir,
        do: System.put_env("TMPDIR", original_tmpdir),
        else: System.delete_env("TMPDIR")
    end)

    planted = Path.join(dir, "doctrans-soffice-XXXXXXXXXX")
    File.mkdir!(planted)
    marker = Path.join(planted, "marker")
    File.write!(marker, "do not reuse")
    profile_file = Path.join(dir, "profile")

    fake =
      make_fake_soffice(dir, """
      #!/bin/sh
      echo "${1#-env:UserInstallation=file://}" > "#{profile_file}"
      #{fake_soffice_body()}
      """)

    put_config(soffice_path: fake, timeout: 10_000)
    source = make_source(dir, "book.docx")

    profiles =
      for _ <- 1..2 do
        assert {:ok, _} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
        profile = File.read!(profile_file) |> String.trim() |> URI.decode()
        assert Path.dirname(profile) == dir
        refute File.exists?(profile)
        profile
      end

    assert length(Enum.uniq(profiles)) == 2
    refute planted in profiles
    assert File.read!(marker) == "do not reuse"
  end

  defp process_gone?(pid) do
    {_output, status} = System.cmd("/bin/ps", ["-p", pid], env: [])
    status != 0
  end

  test "reports a missing PDF after a successful process exit" do
    dir = tmp_dir()
    fake = make_fake_soffice(dir, "#!/bin/sh\nexit 0\n")
    put_config(soffice_path: fake)
    source = make_source(dir, "book.docx")
    assert {:error, message} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
    assert message =~ "PDF file not found"
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end

  # Emulates a soffice conversion: finds --outdir and the last argument (the
  # source file) and "converts" it by touching the expected <base>.pdf.
  #
  # The shebang matters: the converter execs the fake directly via a port.
  defp fake_soffice_body do
    """
    #!/bin/sh
    outdir=""
    src=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--outdir" ]; then outdir="$a"; fi
      src="$a"
      prev="$a"
    done
    base="${src##*/}"
    base="${base%.*}"
    echo "conversion complete"
    : > "$outdir/$base.pdf"
    """
  end
end
