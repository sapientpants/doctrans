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

  import Doctrans.ProcessProbe

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
      assert {:source_file_not_found, [path: _]} = message
    end

    test "fails fast with a clear error when LibreOffice is not installed" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)
      source = make_source(dir, "test.docx")

      put_config(search_paths: [])
      swap_path("")

      result = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))

      assert {:error, message} = result
      assert :soffice_not_found = message
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
      assert {:conversion_failed, [error: "boom: bad file"]} = message
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

      fake = make_fake_soffice(dir, "#!/bin/sh\nexec /bin/sleep 98765\n")

      # 2_000 rather than the 800 this ran at. soffice has to be seen alive
      # before the deadline kills it, and seeing it costs a `/bin/ps` — itself a
      # process launch, and a launch can stall for most of a second before its
      # first instruction runs.
      put_config(soffice_path: fake, timeout: 2_000)

      source = make_source(dir, "book.docx")
      output_dir = Path.join(dir, "out")

      start = System.monotonic_time(:millisecond)
      task = Task.async(fn -> DocumentConverter.convert_to_pdf(source, output_dir) end)

      # Read from the port rather than from a pid file. The file was worse than
      # slow: the deadline SIGKILLs the process group, and a shell still starting
      # up when that lands never writes it at all, so `File.read!` raised
      # `File.Error` instead of failing an assertion.
      soffice = await_os_pid(task.pid, fake, "soffice to be spawned")

      # The vacuity guard: "soffice is gone" is true of a soffice that never
      # started, so it is observed alive before it is awaited gone.
      refute process_gone?(soffice), "soffice #{soffice} was never running"

      assert {:error, :conversion_timeout} = Task.await(task, 30_000)
      assert System.monotonic_time(:millisecond) - start >= 2_000

      eventually(fn -> process_gone?(soffice) end, "soffice #{soffice} to be reaped")
    end
  end

  test "a partial PDF and continuous output do not turn a timeout into success" do
    dir = tmp_dir()
    fake = make_fake_soffice(dir, fake_soffice_body() <> "while :; do echo still-running; done\n")
    put_config(soffice_path: fake, timeout: 300)
    source = make_source(dir, "book.docx")
    started = System.monotonic_time(:millisecond)

    assert {:error, message} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
    assert :conversion_timeout = message
    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "cleans up the process, the child it forked, and the profile when the caller is killed" do
    dir = tmp_dir()
    profile_file = Path.join(dir, "profile")

    # A launcher that forks and waits, the way LibreOffice does. The group kill
    # is asserted here rather than on the timeout path, because whether a
    # grandchild exists at all is not something a timing-out run can promise: the
    # launcher may still be starting up when its deadline kills it. Nothing races
    # the observation under a 60-second deadline, and caller death reaps through
    # the same `kill_group/1` call a deadline uses.
    fake =
      make_fake_soffice(dir, """
      #!/bin/sh
      echo "${1#-env:UserInstallation=file://}" > "#{profile_file}"
      /bin/sleep 98765 &
      wait
      """)

    put_config(soffice_path: fake, timeout: 60_000)
    source = make_source(dir, "book.docx")
    caller = spawn(fn -> DocumentConverter.convert_to_pdf(source, Path.join(dir, "out")) end)
    on_exit(fn -> Process.exit(caller, :kill) end)

    soffice = await_os_pid(caller, fake, "soffice to be spawned")
    child = await_child_pid(soffice, "soffice to fork its child")

    refute process_gone?(soffice), "soffice #{soffice} was never running"
    refute process_gone?(child), "soffice child #{child} was never running"

    profile =
      profile_file
      |> await_file_line("soffice to record the profile it was given")
      |> URI.decode()

    assert File.dir?(profile)
    assert Bitwise.band(File.stat!(profile).mode, 0o777) == 0o700
    Process.exit(caller, :kill)

    eventually(fn -> process_gone?(soffice) end, "soffice #{soffice} to be reaped")
    eventually(fn -> process_gone?(child) end, "soffice child #{child} to be reaped")
    eventually(fn -> not File.exists?(profile) end, "the profile #{profile} to be removed")
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

    launcher =
      ready |> await_file_line("the launcher to record its own pid") |> String.to_integer()

    child = Path.join(dir, "child") |> await_file_line("the launcher to record its child's pid")
    # The port is found by the executable it was spawned as, and its owner is the
    # process it is connected to: a task monitors more than the owner
    # `supervised/1` gives it, so matching a single monitor can raise instead.
    port = find_port(task.pid, fake)
    {:connected, owner} = :erlang.port_info(port, :connected)

    # Hold the owner until the launcher has exited. PID lookup must still work
    # at this point, even if the owner was descheduled immediately after open.
    :erlang.suspend_process(owner)

    try do
      File.touch!(release)
      eventually(fn -> process_gone?(launcher) end, "launcher #{launcher} to exit")
      refute process_gone?(child), "launcher child #{child} should outlive the launcher"
      assert Port.info(port, :os_pid) == {:os_pid, launcher}
    after
      :erlang.resume_process(owner)
    end

    assert {:error, _message} = Task.await(task, 5_000)
    eventually(fn -> process_gone?(child) end, "launcher child #{child} to be reaped")
  end

  test "EOF without process exit still times out and cleans up" do
    dir = tmp_dir()
    fake = make_fake_soffice(dir, "#!/bin/sh\nexec 1>&- 2>&-\nexec /bin/sleep 30\n")
    put_config(soffice_path: fake, timeout: 800)
    source = make_source(dir, "book.docx")

    assert {:error, message} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
    assert :conversion_timeout = message
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

  test "reports a missing PDF after a successful process exit" do
    dir = tmp_dir()
    fake = make_fake_soffice(dir, "#!/bin/sh\nexit 0\n")
    put_config(soffice_path: fake)
    source = make_source(dir, "book.docx")
    assert {:error, message} = DocumentConverter.convert_to_pdf(source, Path.join(dir, "out"))
    assert :converted_pdf_not_found = message
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
