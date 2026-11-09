defmodule Doctrans.Processing.PdfExtractorBoundsTest do
  @moduledoc """
  Tests the bounds around poppler: deadlines, child cleanup, bounded
  diagnostics, and the page and image limits.

  These tests run with `async: false` because they temporarily mutate the
  `:doctrans` application environment and `$PATH` (restored afterwards).

  Fakes are spawned through `Port.open/2`'s `:spawn_executable`, which execs the
  file directly, so every fake must carry a `#!/bin/sh` shebang.
  """
  use Doctrans.EnvCase, async: false

  import Doctrans.ProcessProbe

  # The fakes below deliberately fail, and the extractor logs each failure with
  # its diagnostic tail. Capturing keeps that out of the suite's output.
  @moduletag :capture_log

  alias Doctrans.Processing.PdfExtractor
  alias Doctrans.TestEnv

  setup do
    original_config = Application.get_env(:doctrans, :pdf_extraction, [])
    original_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", original_path) end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "extractor_bounds_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, config: original_config}
  end

  defp put_config(config, overrides),
    do: TestEnv.put_env(:pdf_extraction, Keyword.merge(config, overrides))

  defp fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  # A pdfinfo that prints exactly these lines, the way the real one lays them
  # out: `Pages:` after the Info dictionary, then one `Page N size:` line (and
  # a `rot:` line) per page in the range it was asked for.
  defp fake_pdfinfo(dir, lines) do
    fake(dir, "pdfinfo", Enum.map_join(["#!/bin/sh" | lines], "\n", & &1) <> "\n")
  end

  # What pdfinfo prints for one letter-sized page: the geometry every render
  # measures first, so every test that renders needs a pdfinfo that reports it.
  defp letter_pdfinfo(dir, page_number \\ 1) do
    fake_pdfinfo(dir, [
      ~s(echo "Pages:           #{page_number}"),
      ~s(echo "Page    #{page_number} size:  612 x 792 pts \(letter\)"),
      ~s(echo "Page    #{page_number} rot:   0")
    ])
  end

  # Renders one blank "page" per requested page number, the way pdftoppm names
  # them: <prefix>-01.png. The prefix is the last argument.
  defp fake_pdftoppm_body(page_number \\ 1) do
    """
    #!/bin/sh
    prefix=""
    for a in "$@"; do prefix="$a"; done
    printf 'rendered' > "${prefix}-#{String.pad_leading(to_string(page_number), 2, "0")}.png"
    """
  end

  defp source_pdf(dir) do
    path = Path.join(dir, "book.pdf")
    File.write!(path, "%PDF-1.4\n")
    path
  end

  describe "deadlines" do
    test "a hung renderer times out, is reaped, and frees the slot", %{dir: dir, config: config} do
      hung = fake(dir, "pdftoppm", "#!/bin/sh\nexec /bin/sleep 98765\n")

      # 2_000 rather than the 500 this ran at. The renderer has to be seen alive
      # before the deadline kills it, and seeing it costs a `/bin/ps` — itself a
      # process launch, and a launch can stall for most of a second before its
      # first instruction runs. The deadline has to exceed that stall, not merely
      # the scheduler. Lengthening the poll budget instead would be no help: this
      # is a window that closes, not a wait that is slow.
      put_config(config, pdftoppm_path: hung, pdfinfo_path: letter_pdfinfo(dir), timeout: 2_000)
      pages_dir = Path.join(dir, "pages")

      started = System.monotonic_time(:millisecond)
      task = Task.async(fn -> PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1) end)

      # Read from the port rather than from a file the fake writes: the deadline
      # SIGKILLs the whole process group, and a shell still starting up when that
      # lands never runs the line that would have recorded its pid.
      renderer = await_os_pid(task.pid, hung, "the renderer to be spawned")

      # The vacuity guard, and the reason this test is worth anything: "the
      # renderer is gone" is true of a renderer that was never started, so it is
      # observed alive before it is awaited gone.
      refute process_gone?(renderer), "renderer #{renderer} was never running"

      assert {:error, :pdf_command_timeout} = Task.await(task, 30_000)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 2_000

      eventually(fn -> process_gone?(renderer) end, "renderer #{renderer} to be reaped")

      # The single extraction slot is free again: a working renderer runs next.
      put_config(config,
        pdftoppm_path: fake(dir, "pdftoppm", fake_pdftoppm_body()),
        pdfinfo_path: letter_pdfinfo(dir)
      )

      assert {:ok, path} = PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1)
      assert Path.basename(path) == "page-01.png"
    end

    test "the renderer's children are reaped with it, not left behind", %{
      dir: dir,
      config: config
    } do
      # Split out of the test above deliberately. Whether a grandchild exists at
      # all is not something a timing-out run can promise: the renderer may still
      # be starting up when its deadline kills it, so no forked child is ever
      # visible. Under a 60-second deadline nothing is racing the observation,
      # and killing the caller reaps through the same `kill_group/1` path a
      # deadline uses, so the claim under test is unchanged.
      forking =
        fake(dir, "pdftoppm", """
        #!/bin/sh
        /bin/sleep 98765 &
        wait
        """)

      put_config(config,
        pdftoppm_path: forking,
        pdfinfo_path: letter_pdfinfo(dir),
        timeout: 60_000
      )

      pages_dir = Path.join(dir, "pages")

      caller = spawn(fn -> PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1) end)
      on_exit(fn -> Process.exit(caller, :kill) end)

      renderer = await_os_pid(caller, forking, "the renderer to be spawned")
      child = await_child_pid(renderer, "the renderer to fork its child")

      refute process_gone?(renderer), "renderer #{renderer} was never running"
      refute process_gone?(child), "renderer child #{child} was never running"

      Process.exit(caller, :kill)

      eventually(fn -> process_gone?(renderer) end, "renderer #{renderer} to be reaped")
      eventually(fn -> process_gone?(child) end, "renderer child #{child} to be reaped")
    end

    test "a hung pdfinfo times out instead of waiting forever", %{dir: dir, config: config} do
      hung = fake(dir, "pdfinfo", "#!/bin/sh\nexec /bin/sleep 98765\n")
      put_config(config, pdfinfo_path: hung, info_timeout: 300)

      # A hung pdfinfo is not a rendering problem, so it does not advise lowering
      # the resolution: nothing was rendered.
      assert {:error, :pdfinfo_timeout} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "output does not extend the deadline", %{dir: dir, config: config} do
      chatty = fake(dir, "pdftoppm", "#!/bin/sh\nwhile :; do echo still-rendering; done\n")
      put_config(config, pdftoppm_path: chatty, pdfinfo_path: letter_pdfinfo(dir), timeout: 400)

      started = System.monotonic_time(:millisecond)

      assert {:error, :pdf_command_timeout} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)

      assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end

  describe "diagnostics" do
    test "a flood of error output is bounded in the reported reason", %{dir: dir, config: config} do
      noisy =
        fake(dir, "pdftoppm", """
        #!/bin/sh
        i=0
        while [ $i -lt 4000 ]; do
          echo "0123456789012345678901234567890123456789012345678901234567890123456789"
          i=$((i + 1))
        done
        exit 1
        """)

      put_config(config, pdftoppm_path: noisy, pdfinfo_path: letter_pdfinfo(dir), timeout: 30_000)

      assert {:error, {:pdf_command_failed, [error: output]}} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)

      # The fake writes roughly 280 KB; only the most recent 64 KiB is retained.
      assert byte_size(output) <= 64 * 1024
      assert String.ends_with?(output, "0123456789")
    end
  end

  describe "resource limits" do
    test "a document above :max_pages is rejected before any page renders", %{
      dir: dir,
      config: config
    } do
      counting = fake_pdfinfo(dir, [~s(echo "Pages:          4200")])
      put_config(config, pdfinfo_path: counting, max_pages: 1_000)

      assert {:error, {:pdf_too_many_pages, [pages: 4200, limit: 1_000]}} =
               PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a page count within :max_pages is returned", %{dir: dir, config: config} do
      counting =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           2"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    2 size:  612 x 792 pts \(letter\)")
        ])

      put_config(config, pdfinfo_path: counting, max_pages: 1_000)

      assert {:ok, 2} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "an oversized page image is reported and removed", %{dir: dir, config: config} do
      fat =
        fake(dir, "pdftoppm", """
        #{fake_pdftoppm_body()}
        prefix=""
        for a in "$@"; do prefix="$a"; done
        /usr/bin/head -c 4096 /dev/zero > "${prefix}-01.png"
        """)

      put_config(config,
        pdftoppm_path: fat,
        pdfinfo_path: letter_pdfinfo(dir),
        timeout: 30_000,
        max_image_bytes: 1_024
      )

      pages_dir = Path.join(dir, "pages")

      assert {:error, {:page_image_too_large, bindings}} =
               PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1)

      assert bindings[:page_number] == 1
      assert bindings[:size] == 4096
      assert bindings[:limit] == 1_024

      # Leaving the file behind would make a lower :dpi setting take no effect,
      # because extraction treats a stored image as a finished page.
      assert Path.wildcard(Path.join(pages_dir, "page-*.png")) == []
    end

    test "an image within :max_image_bytes is kept", %{dir: dir, config: config} do
      put_config(config,
        pdftoppm_path: fake(dir, "pdftoppm", fake_pdftoppm_body()),
        pdfinfo_path: letter_pdfinfo(dir),
        max_image_bytes: 1_024
      )

      pages_dir = Path.join(dir, "pages")

      assert {:ok, path} = PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1)
      assert File.read!(path) == "rendered"
    end
  end

  describe "executable resolution" do
    test "a missing renderer is named in the error", %{dir: dir, config: config} do
      # The fallback directories are pinned off, so this really is "nothing to
      # find" rather than "found the machine's own poppler".
      put_config(config,
        pdftoppm_path: Path.join(dir, "nope"),
        pdfinfo_path: Path.join(dir, "nope"),
        search_dirs: []
      )

      System.put_env("PATH", "")

      assert {:error, {:poppler_not_found, [command: "pdftoppm"]}} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)

      assert {:error, {:poppler_not_found, [command: "pdfinfo"]}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      refute PdfExtractor.available?()
    end

    test "a configured path that is not executable falls back to $PATH", %{
      dir: dir,
      config: config
    } do
      not_executable = Path.join(dir, "pdftoppm.txt")
      File.write!(not_executable, "#!/bin/sh\n")

      on_path = Path.join(dir, "bin")
      File.mkdir_p!(on_path)
      fake(on_path, "pdftoppm", fake_pdftoppm_body())
      # available?/0 needs both commands: every extraction calls pdfinfo first.
      letter_pdfinfo(on_path)

      put_config(config, pdftoppm_path: not_executable, timeout: 30_000, search_dirs: [])
      System.put_env("PATH", on_path)

      assert PdfExtractor.available?()

      assert {:ok, _path} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)
    end
  end

  describe "page geometry" do
    test "a page too large to rasterize is rejected before any render", %{
      dir: dir,
      config: config
    } do
      # A 20000x20000pt media box is ~278in square; at 150 dpi that is over a
      # billion pixels, which would be gigabytes of RAM and PNG before the
      # post-render byte check could ever see it.
      huge =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           1"),
          ~s(echo "Page    1 size:  20000 x 20000 pts"),
          ~s(echo "Page    1 rot:   0")
        ])

      put_config(config, pdfinfo_path: huge, dpi: 150, max_page_pixels: 40_000_000)

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert bindings[:page_number] == 1
      assert bindings[:limit] == 40_000_000
      assert bindings[:dpi] == 150
      assert bindings[:pixels] > 40_000_000
    end

    test "every page is asked for, up to the page limit", %{dir: dir, config: config} do
      # Without a range pdfinfo reports the first page's size only. The range
      # is what makes the check below cover the whole document, so the fake
      # records what it was asked for.
      recorded = Path.join(dir, "pdfinfo.args")

      recording =
        fake_pdfinfo(dir, [
          ~s[printf '%s\\n' "$@" > "#{recorded}"],
          ~s(echo "Pages:           1"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)")
        ])

      put_config(config, pdfinfo_path: recording, max_pages: 250)

      pdf = source_pdf(dir)
      assert {:ok, 1} = PdfExtractor.get_page_count(pdf)
      assert File.read!(recorded) == "-f\n1\n-l\n250\n#{pdf}\n"
    end

    test "a small first page does not vouch for the pages behind it", %{
      dir: dir,
      config: config
    } do
      mixed =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           3"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    1 rot:   0"),
          ~s(echo "Page    2 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    2 rot:   0"),
          ~s(echo "Page    3 size:  14400 x 14400 pts"),
          ~s(echo "Page    3 rot:   0")
        ])

      put_config(config, pdfinfo_path: mixed, dpi: 150, max_page_pixels: 40_000_000)

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert bindings[:page_number] == 3
    end

    test "a size pdfinfo prints in exponent notation is still measured", %{
      dir: dir,
      config: config
    } do
      # pdfinfo formats dimensions with %g, so from a million points up they
      # print as `1e+06`. A pattern that only admitted digits dropped exactly
      # this line, and with it the page the bound exists for.
      exponent =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           2"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    1 rot:   0"),
          ~s(echo "Page    2 size:  1e+06 x 1e+06 pts"),
          ~s(echo "Page    2 rot:   0")
        ])

      put_config(config, pdfinfo_path: exponent, dpi: 150, max_page_pixels: 40_000_000)

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert bindings[:page_number] == 2
      assert bindings[:width] == 2_083_334
    end

    test "a page without a size line fails the document", %{dir: dir, config: config} do
      # Two pages, one size line: the page that was not measured is the one a
      # bound that stops at "some geometry was reported" would render on trust.
      short =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           2"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)")
        ])

      put_config(config, pdfinfo_path: short, max_page_pixels: 40_000_000)

      assert {:error, :invalid_page_size} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a size that does not read as a number fails the document", %{
      dir: dir,
      config: config
    } do
      # Formerly parsed as 0.0, which is zero pixels, which is under any limit.
      unreadable =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           1"),
          ~s(echo "Page    1 size:  . x 792 pts")
        ])

      put_config(config, pdfinfo_path: unreadable, max_page_pixels: 40_000_000)

      assert {:error, :invalid_page_size} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a size line inside the document's metadata is not its geometry", %{
      dir: dir,
      config: config
    } do
      # pdfinfo prints the Info dictionary before the page lines, with the
      # metadata's own newlines shown as `?`, so a crafted title can put the
      # words "Page size:" and "Pages:" on the page ahead of the real lines.
      spoofed =
        fake_pdfinfo(dir, [
          ~s(echo "Title:           spoof?Page size: 1 x 1 pts?Pages: 1"),
          ~s(echo "Subject:         Page    1 size:  1 x 1 pts"),
          ~s(echo "Pages:           2"),
          ~s(echo "Page    1 size:  20000 x 20000 pts"),
          ~s(echo "Page    1 rot:   0"),
          ~s(echo "Page    2 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    2 rot:   0")
        ])

      put_config(config, pdfinfo_path: spoofed, dpi: 150, max_page_pixels: 40_000_000)

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert bindings[:page_number] == 1
    end

    test "a page count inside the document's metadata is not its page count", %{
      dir: dir,
      config: config
    } do
      spoofed =
        fake_pdfinfo(dir, [
          ~s(echo "Title:           Pages: 1"),
          ~s(echo "Pages:           30"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)")
        ])

      put_config(config, pdfinfo_path: spoofed, max_pages: 10)

      assert {:error, {:pdf_too_many_pages, [pages: 30, limit: 10]}} =
               PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "ordinary page sizes pass", %{dir: dir, config: config} do
      letter =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           3"),
          ~s(echo "Page    1 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    1 rot:   0"),
          ~s(echo "Page    2 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    2 rot:   0"),
          ~s(echo "Page    3 size:  595.276 x 841.89 pts \(A4\)"),
          ~s(echo "Page    3 rot:   90")
        ])

      put_config(config, pdfinfo_path: letter, dpi: 150, max_page_pixels: 40_000_000)

      assert {:ok, 3} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a build that ignores the range still has its one size line checked", %{
      dir: dir,
      config: config
    } do
      unnumbered =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           1"),
          ~s(echo "Page size:       20000 x 20000 pts")
        ])

      put_config(config, pdfinfo_path: unnumbered, dpi: 150, max_page_pixels: 40_000_000)

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert bindings[:page_number] == 1
    end

    test "output without a page size is rejected rather than rendered on trust", %{
      dir: dir,
      config: config
    } do
      # The geometry check is the one bound that must hold before the render,
      # so output that gives it nothing to check cannot be waved through.
      terse = fake_pdfinfo(dir, [~s(echo "Pages:          2")])
      put_config(config, pdfinfo_path: terse, max_page_pixels: 1)

      assert {:error, :invalid_page_size} = PdfExtractor.get_page_count(source_pdf(dir))
    end
  end

  describe "render geometry" do
    test "the page is measured again before it is rendered", %{dir: dir, config: config} do
      # pdfinfo is asked for the one page about to render, and pdftoppm is told
      # the pixel dimensions that measurement gave at the configured dpi rather
      # than a resolution: letter at 150 dpi is 1275x1650, rounded up the way
      # pdftoppm rounds. A page that read differently to the two tools would
      # still rasterize to no more than what was measured.
      info_args = Path.join(dir, "pdfinfo.args")
      render_args = Path.join(dir, "pdftoppm.args")

      measuring =
        fake_pdfinfo(dir, [
          ~s[printf '%s\\n' "$@" > "#{info_args}"],
          ~s(echo "Pages:           3"),
          ~s(echo "Page    3 size:  612 x 792 pts \(letter\)"),
          ~s(echo "Page    3 rot:   0")
        ])

      recording =
        fake(dir, "pdftoppm", """
        #{fake_pdftoppm_body(3)}
        printf '%s\\n' "$@" > "#{render_args}"
        """)

      put_config(config, pdftoppm_path: recording, pdfinfo_path: measuring, dpi: 150)

      pdf = source_pdf(dir)
      pages_dir = Path.join(dir, "pages")

      assert {:ok, path} = PdfExtractor.extract_page(pdf, pages_dir, 3)
      assert Path.basename(path) == "page-03.png"

      assert File.read!(info_args) == "-f\n3\n-l\n3\n#{pdf}\n"

      assert File.read!(render_args) ==
               "-f\n3\n-l\n3\n-png\n-scale-to-x\n1275\n-scale-to-y\n1650\n#{pdf}\n#{pages_dir}/page\n"
    end

    test "a page measured too large at render time is refused before pdftoppm runs", %{
      dir: dir,
      config: config
    } do
      marker = Path.join(dir, "rendered")

      huge =
        fake_pdfinfo(dir, [
          ~s(echo "Pages:           1"),
          ~s(echo "Page    1 size:  20000 x 20000 pts")
        ])

      put_config(config,
        pdftoppm_path: fake(dir, "pdftoppm", "#!/bin/sh\ntouch \"#{marker}\"\n"),
        pdfinfo_path: huge,
        dpi: 150,
        max_page_pixels: 40_000_000
      )

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)

      assert bindings[:page_number] == 1
      refute File.exists?(marker)
    end

    test "a page pdfinfo reports no size for at render time is not rendered", %{
      dir: dir,
      config: config
    } do
      marker = Path.join(dir, "rendered")

      put_config(config,
        pdftoppm_path: fake(dir, "pdftoppm", "#!/bin/sh\ntouch \"#{marker}\"\n"),
        pdfinfo_path: fake_pdfinfo(dir, [~s(echo "Pages:           1")])
      )

      assert {:error, :invalid_page_size} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)

      refute File.exists?(marker)
    end
  end

  describe "document budget" do
    test "a render is clamped to the caller's remaining budget", %{dir: dir, config: config} do
      hung = fake(dir, "pdftoppm", "#!/bin/sh\nexec /bin/sleep 98765\n")

      # The per-page ceiling is far larger than the budget, so only the budget
      # can be what ends this.
      put_config(config, pdftoppm_path: hung, pdfinfo_path: letter_pdfinfo(dir), timeout: 60_000)
      deadline = System.monotonic_time(:millisecond) + 400

      started = System.monotonic_time(:millisecond)

      assert {:error, :pdf_command_timeout} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1,
                 deadline: deadline
               )

      assert System.monotonic_time(:millisecond) - started < 10_000
    end

    test "an exhausted budget fails without starting a render", %{dir: dir, config: config} do
      marker = Path.join(dir, "ran")

      put_config(config,
        pdftoppm_path: fake(dir, "pdftoppm", "#!/bin/sh\ntouch \"#{marker}\"\n"),
        pdfinfo_path: fake(dir, "pdfinfo", "#!/bin/sh\ntouch \"#{marker}\"\n"),
        timeout: 30_000
      )

      past = System.monotonic_time(:millisecond) - 1

      assert {:error, :pdf_extraction_deadline_exceeded} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1,
                 deadline: past
               )

      refute File.exists?(marker)
    end
  end

  describe "pdfinfo output handling" do
    test "output without a page count is reported as unparseable", %{dir: dir, config: config} do
      # What an encrypted PDF produces.
      encrypted = fake_pdfinfo(dir, [~s(echo "Encrypted:      yes")])
      put_config(config, pdfinfo_path: encrypted)

      assert {:error, :invalid_page_count} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a non-zero pdfinfo exit is reported as a pdfinfo failure", %{dir: dir, config: config} do
      broken =
        fake_pdfinfo(dir, [
          ~s(echo "Command Line Error: wrong password" >&2),
          "exit 1"
        ])

      put_config(config, pdfinfo_path: broken)

      assert {:error, {:pdfinfo_failed, [error: error]}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert error =~ "wrong password"
    end
  end

  describe "render output handling" do
    test "a renderer that exits cleanly but writes nothing is reported", %{
      dir: dir,
      config: config
    } do
      silent = fake(dir, "pdftoppm", "#!/bin/sh\nexit 0\n")

      put_config(config,
        pdftoppm_path: silent,
        pdfinfo_path: letter_pdfinfo(dir),
        timeout: 30_000
      )

      assert {:error, :page_image_not_found} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)
    end
  end
end
