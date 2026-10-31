defmodule Scripts.CheckRawCallSitesTest do
  @moduledoc """
  Smoke-tests the pre-commit gate in `scripts/check_raw_call_sites.exs`.

  The register inside the script names the two files allowed one `raw/1` site
  each, so every fixture tree starts from those two files and then drifts in
  one direction: a site appears somewhere new, a registered file grows a
  second one, or a registered site disappears.
  """
  use ExUnit.Case, async: true

  import Doctrans.GateScript, only: [run: 3, write: 3]

  @moduletag :tmp_dir
  @script "check_raw_call_sites.exs"

  @registered [
    "lib/doctrans_web/live/document_live/viewer_components.ex",
    "lib/doctrans_web/live/document_live/chat_components.ex"
  ]

  @one_site "defmodule Example do\n  def body(html), do: raw(html)\nend\n"

  setup %{tmp_dir: dir} do
    Enum.each(@registered, &write(dir, &1, @one_site))
    :ok
  end

  test "a tree matching the register passes", %{tmp_dir: dir} do
    assert {output, 0} = run(@script, [], dir)
    assert output =~ "raw/1 call sites match the register (2 files, 2 sites)"
  end

  test "a raw/1 site in an unregistered file fails", %{tmp_dir: dir} do
    write(dir, "lib/doctrans_web/components/new.ex", @one_site)

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "lib/doctrans_web/components/new.ex: 1 unregistered raw/1 site(s)"
  end

  test "a second site in a registered file fails with both counts", %{tmp_dir: dir} do
    [viewer | _] = @registered
    write(dir, viewer, @one_site <> "raw(more)\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{viewer}: 2 raw/1 site(s), register says 1"
  end

  test "a registered file that lost its site is reported as a stale entry", %{tmp_dir: dir} do
    [_, chat] = @registered
    write(dir, chat, "defmodule Example do\nend\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{chat}: registered 1 raw/1 site(s), found none — stale register entry"
  end

  test "the fully qualified Phoenix.HTML.raw/1 counts as a site", %{tmp_dir: dir} do
    write(dir, "lib/doctrans_web/qualified.heex", "<div>{Phoenix.HTML.raw(@html)}</div>\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "lib/doctrans_web/qualified.heex: 1 unregistered raw/1 site(s)"
  end

  test "comments and identifiers that merely end in raw are not sites", %{tmp_dir: dir} do
    write(dir, "lib/doctrans_web/innocent.ex", """
    defmodule Innocent do
      # Never call raw(html) here; see scripts/check_raw_call_sites.exs.
      def convert(x), do: to_raw(x)
      def draw(x), do: x.raw(x)
    end
    """)

    assert {_output, 0} = run(@script, [], dir)
  end
end
