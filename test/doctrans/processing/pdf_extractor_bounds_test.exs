defmodule Doctrans.Processing.PdfExtractorBoundsTest do
  @moduledoc """
  Tests the bounds R04 put around poppler: deadlines, child cleanup, bounded
  diagnostics, and the page and image limits.

  These tests run with `async: false` because they temporarily mutate the
  `:doctrans` application environment and `$PATH` (restored afterwards).

  Fakes are spawned through `Port.open/2`'s `:spawn_executable`, which execs the
  file directly, so every fake must carry a `#!/bin/sh` shebang.
  """
  use ExUnit.Case, async: false

  # The fakes below deliberately fail, and the extractor logs each failure with
  # its diagnostic tail. Capturing keeps that out of the suite's output.
  @moduletag :capture_log

  alias Doctrans.Processing.PdfExtractor

  setup do
    original_config = Application.get_env(:doctrans, :pdf_extraction, [])
    original_path = System.get_env("PATH")

    on_exit(fn ->
      Application.put_env(:doctrans, :pdf_extraction, original_config)
      System.put_env("PATH", original_path)
    end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "extractor_bounds_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, config: original_config}
  end

  defp put_config(config, overrides) do
    Application.put_env(:doctrans, :pdf_extraction, Keyword.merge(config, overrides))
  end

  defp fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  # Renders one blank "page" per requested page number, the way pdftoppm names
  # them: <prefix>-01.png. The prefix is the last argument.
  defp fake_pdftoppm_body do
    """
    #!/bin/sh
    prefix=""
    for a in "$@"; do prefix="$a"; done
    printf 'rendered' > "${prefix}-01.png"
    """
  end

  defp source_pdf(dir) do
    path = Path.join(dir, "book.pdf")
    File.write!(path, "%PDF-1.4\n")
    path
  end

  defp process_gone?(pid) do
    {_output, status} = System.cmd("/bin/ps", ["-p", pid], env: [])
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

  describe "deadlines" do
    test "a hung renderer times out, is reaped, and frees the slot", %{dir: dir, config: config} do
      pid_file = Path.join(dir, "pid")

      hung =
        fake(dir, "pdftoppm", """
        #!/bin/sh
        /bin/sleep 98765 &
        echo $! > "#{pid_file}.child"
        echo $$ > "#{pid_file}"
        wait
        """)

      put_config(config, pdftoppm_path: hung, timeout: 500)
      pages_dir = Path.join(dir, "pages")

      started = System.monotonic_time(:millisecond)
      result = PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1)
      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, :pdf_command_timeout} = result
      assert elapsed >= 500

      # The fake writes these from a forked shell; on a loaded runner the write
      # can land after the deadline that killed it.
      eventually(fn -> File.exists?(pid_file) and File.exists?(pid_file <> ".child") end)

      renderer = pid_file |> File.read!() |> String.trim()
      child = (pid_file <> ".child") |> File.read!() |> String.trim()
      eventually(fn -> process_gone?(renderer) end)
      eventually(fn -> process_gone?(child) end)

      # The single extraction slot is free again: a working renderer runs next.
      put_config(config, pdftoppm_path: fake(dir, "pdftoppm", fake_pdftoppm_body()))

      assert {:ok, path} = PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1)
      assert Path.basename(path) == "page-01.png"
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
      put_config(config, pdftoppm_path: chatty, timeout: 400)

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

      put_config(config, pdftoppm_path: noisy, timeout: 30_000)

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
      counting =
        fake(dir, "pdfinfo", """
        #!/bin/sh
        echo "Pages:          4200"
        """)

      put_config(config, pdfinfo_path: counting, max_pages: 1_000)

      assert {:error, {:pdf_too_many_pages, [pages: 4200, limit: 1_000]}} =
               PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a page count within :max_pages is returned", %{dir: dir, config: config} do
      counting = fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          12\"\n")
      put_config(config, pdfinfo_path: counting, max_pages: 1_000)

      assert {:ok, 12} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "an oversized page image is reported and removed", %{dir: dir, config: config} do
      fat =
        fake(dir, "pdftoppm", """
        #{fake_pdftoppm_body()}
        prefix=""
        for a in "$@"; do prefix="$a"; done
        /usr/bin/head -c 4096 /dev/zero > "${prefix}-01.png"
        """)

      put_config(config, pdftoppm_path: fat, timeout: 30_000, max_image_bytes: 1_024)
      pages_dir = Path.join(dir, "pages")

      assert {:error, {:page_image_too_large, bindings}} =
               PdfExtractor.extract_page(source_pdf(dir), pages_dir, 1)

      assert bindings[:page_number] == 1
      assert bindings[:size] == 4096
      assert bindings[:limit] == 1_024

      # Leaving the file behind would make a lower :dpi setting take no effect,
      # because extraction treats a stored image as a finished page.
      assert PdfExtractor.page_image_path(pages_dir, 1) == nil
    end

    test "an image within :max_image_bytes is kept", %{dir: dir, config: config} do
      put_config(config,
        pdftoppm_path: fake(dir, "pdftoppm", fake_pdftoppm_body()),
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
      put_config(config, pdftoppm_path: Path.join(dir, "nope"), search_dirs: [])
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
      fake(on_path, "pdfinfo", "#!/bin/sh\necho \"Pages:          1\"\n")

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
        fake(dir, "pdfinfo", """
        #!/bin/sh
        echo "Pages:          1"
        echo "Page size:      20000 x 20000 pts"
        """)

      put_config(config, pdfinfo_path: huge, dpi: 150, max_page_pixels: 40_000_000)

      assert {:error, {:pdf_page_too_large, bindings}} =
               PdfExtractor.get_page_count(source_pdf(dir))

      assert bindings[:limit] == 40_000_000
      assert bindings[:dpi] == 150
      assert bindings[:pixels] > 40_000_000
    end

    test "an ordinary page size passes", %{dir: dir, config: config} do
      letter =
        fake(dir, "pdfinfo", """
        #!/bin/sh
        echo "Pages:          3"
        echo "Page size:      612 x 792 pts (letter)"
        """)

      put_config(config, pdfinfo_path: letter, dpi: 150, max_page_pixels: 40_000_000)

      assert {:ok, 3} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "output without a page size is accepted rather than guessed at", %{
      dir: dir,
      config: config
    } do
      terse = fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          2\"\n")
      put_config(config, pdfinfo_path: terse, max_page_pixels: 1)

      assert {:ok, 2} = PdfExtractor.get_page_count(source_pdf(dir))
    end
  end

  describe "document budget" do
    test "a render is clamped to the caller's remaining budget", %{dir: dir, config: config} do
      hung = fake(dir, "pdftoppm", "#!/bin/sh\nexec /bin/sleep 98765\n")

      # The per-page ceiling is far larger than the budget, so only the budget
      # can be what ends this.
      put_config(config, pdftoppm_path: hung, timeout: 60_000)
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
      encrypted =
        fake(dir, "pdfinfo", "#!/bin/sh\necho \"Encrypted:      yes\"\n")

      put_config(config, pdfinfo_path: encrypted)

      assert {:error, :invalid_page_count} = PdfExtractor.get_page_count(source_pdf(dir))
    end

    test "a non-zero pdfinfo exit is reported as a pdfinfo failure", %{dir: dir, config: config} do
      broken =
        fake(
          dir,
          "pdfinfo",
          "#!/bin/sh\necho \"Command Line Error: wrong password\" >&2\nexit 1\n"
        )

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
      put_config(config, pdftoppm_path: silent, timeout: 30_000)

      assert {:error, :page_image_not_found} =
               PdfExtractor.extract_page(source_pdf(dir), Path.join(dir, "pages"), 1)
    end
  end

  describe "extract_pages/3" do
    test "the page limit applies to the whole-document path too", %{dir: dir, config: config} do
      put_config(config,
        pdfinfo_path: fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          2\"\n"),
        pdftoppm_path: fake(dir, "pdftoppm", fake_pdftoppm_body()),
        max_pages: 1,
        timeout: 30_000
      )

      assert {:error, {:pdf_too_many_pages, [pages: 2, limit: 1]}} =
               PdfExtractor.extract_pages(source_pdf(dir), Path.join(dir, "pages"))

      put_config(config,
        pdfinfo_path: fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          1\"\n"),
        pdftoppm_path: fake(dir, "pdftoppm", fake_pdftoppm_body()),
        max_pages: 10,
        timeout: 30_000
      )

      assert {:ok, 1} = PdfExtractor.extract_pages(source_pdf(dir), Path.join(dir, "pages"))
    end

    test "a malformed page count does not become a zero-millisecond deadline", %{
      dir: dir,
      config: config
    } do
      slow =
        fake(dir, "pdftoppm", """
        #{fake_pdftoppm_body()}
        /bin/sleep 0.2
        """)

      put_config(config,
        pdfinfo_path: fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          0\"\n"),
        pdftoppm_path: slow,
        timeout: 10_000
      )

      assert {:ok, 1} = PdfExtractor.extract_pages(source_pdf(dir), Path.join(dir, "pages"))
    end

    test "the whole-document deadline never exceeds the job budget", %{dir: dir, config: config} do
      hung = fake(dir, "pdftoppm", "#!/bin/sh\nexec /bin/sleep 98765\n")

      # 500 pages at the per-page ceiling would be far longer than the job can
      # run; the job budget is what has to bind.
      put_config(config,
        pdfinfo_path: fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          500\"\n"),
        pdftoppm_path: hung,
        max_pages: 1_000,
        timeout: 60_000,
        job_timeout: 400
      )

      started = System.monotonic_time(:millisecond)

      assert {:error, :pdf_command_timeout} =
               PdfExtractor.extract_pages(source_pdf(dir), Path.join(dir, "pages"))

      assert System.monotonic_time(:millisecond) - started < 10_000
    end

    test "every oversized render is removed, not just the first", %{dir: dir, config: config} do
      fat =
        fake(dir, "pdftoppm", """
        #!/bin/sh
        prefix=""
        for a in "$@"; do prefix="$a"; done
        /usr/bin/head -c 4096 /dev/zero > "${prefix}-01.png"
        /usr/bin/head -c 4096 /dev/zero > "${prefix}-02.png"
        """)

      put_config(config,
        pdfinfo_path: fake(dir, "pdfinfo", "#!/bin/sh\necho \"Pages:          2\"\n"),
        pdftoppm_path: fat,
        max_pages: 10,
        timeout: 30_000,
        max_image_bytes: 1_024
      )

      pages_dir = Path.join(dir, "pages")

      assert {:error, {:page_image_too_large, _bindings}} =
               PdfExtractor.extract_pages(source_pdf(dir), pages_dir)

      # A leftover image is what a retry reads as "this page is already done", so
      # stopping at the first offender would strand the rest.
      assert PdfExtractor.list_page_images(pages_dir) == []
    end
  end
end
