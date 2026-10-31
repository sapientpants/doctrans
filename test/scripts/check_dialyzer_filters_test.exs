defmodule Scripts.CheckDialyzerFiltersTest do
  @moduledoc """
  Smoke-tests the pre-commit gate in `scripts/check_dialyzer_filters.exs`.

  The register is a list of `{file, class, line}` tuples, each preceded by four
  annotation comments. The script reads it twice -- as text, for the comments,
  and evaluated, for the tuples -- and every rule it enforces gets one fixture
  that breaks it. `--today` pins the expiry comparison so the cases cannot age.
  """
  use ExUnit.Case, async: true

  import Doctrans.GateScript, only: [run: 3, write: 3]

  @moduletag :tmp_dir
  @script "check_dialyzer_filters.exs"
  @today ["--today", "2026-06-01"]

  @entry """
    # owner: @someone
    # expires: 2026-12-31
    # upstream: none
    # rationale: a deliberate fallback clause that every caller currently skips;
    #   re-decide at expiry.
    {"lib/example.ex", :pattern_match_cov, 12},
  """

  setup %{tmp_dir: dir} do
    write(dir, "lib/example.ex", "defmodule Example do\nend\n")
    :ok
  end

  test "a well-formed register passes and reports its next expiry", %{tmp_dir: dir} do
    register(dir, @entry)

    assert {output, 0} = run(@script, @today, dir)
    assert output =~ "1/8 Dialyzer suppressions, all owned and dated"
    assert output =~ "next expiry 2026-12-31, today 2026-06-01"
  end

  test "an empty register passes", %{tmp_dir: dir} do
    register(dir, "")

    assert {output, 0} = run(@script, @today, dir)
    assert output =~ "0/8 Dialyzer suppressions"
  end

  test "an entry past its expiry fails", %{tmp_dir: dir} do
    register(dir, @entry)

    assert {output, 1} = run(@script, ["--today", "2027-01-01"], dir)
    assert output =~ "expired on 2026-12-31 — re-decide it, or re-date it with a reason"
  end

  test "an expiry that is not an ISO date fails", %{tmp_dir: dir} do
    register(dir, String.replace(@entry, "2026-12-31", "soon"))

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ ~s(`# expires:` must be an ISO date, got "soon")
  end

  test "a missing annotation fails and names the key", %{tmp_dir: dir} do
    register(dir, String.replace(@entry, "  # owner: @someone\n", ""))

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "missing `# owner:` annotation"
  end

  test "a blank annotation counts as missing", %{tmp_dir: dir} do
    register(dir, String.replace(@entry, "# upstream: none", "# upstream:"))

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "missing `# upstream:` annotation"
  end

  test "a file-level mute is refused", %{tmp_dir: dir} do
    register(
      dir,
      String.replace(
        @entry,
        ~s({"lib/example.ex", :pattern_match_cov, 12}),
        ~s({"lib/example.ex", :pattern_match_cov})
      )
    )

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "must be `{file, warning_class, line}`"
    assert output =~ "file-level and class-level mutes hide warnings nobody has read"
  end

  test "a filter naming a file that does not exist fails", %{tmp_dir: dir} do
    register(dir, String.replace(@entry, "lib/example.ex", "lib/moved.ex"))

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "suppresses lib/moved.ex, which does not exist"
  end

  test "a location that is neither a line nor {line, column} fails", %{tmp_dir: dir} do
    register(dir, String.replace(@entry, ", 12}", ", :any}"))

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "location must be `line` or `{line, column}`, got :any"
  end

  test "a filter spread over several lines is refused", %{tmp_dir: dir} do
    register(
      dir,
      String.replace(
        @entry,
        ~s({"lib/example.ex", :pattern_match_cov, 12}),
        ~s({"lib/example.ex",\n    :pattern_match_cov, 12})
      )
    )

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "found 2 entry lines but 1 filters — keep each filter on a single line"
  end

  test "a ninth entry breaks the cap", %{tmp_dir: dir} do
    entries = Enum.map_join(1..9, "\n", &String.replace(@entry, ", 12}", ", #{&1}}"))
    register(dir, entries)

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "register holds 9 entries, cap is 8"
  end

  test "a register that does not evaluate aborts", %{tmp_dir: dir} do
    write(dir, ".dialyzer_ignore.exs", "[\n  {\"lib/example.ex\", :no_return, \n]\n")

    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "cannot evaluate .dialyzer_ignore.exs"
  end

  test "a missing register aborts", %{tmp_dir: dir} do
    assert {output, 1} = run(@script, @today, dir)
    assert output =~ "cannot read .dialyzer_ignore.exs"
  end

  test "a --today that is not an ISO date aborts", %{tmp_dir: dir} do
    register(dir, @entry)

    assert {output, 1} = run(@script, ["--today", "yesterday"], dir)
    assert output =~ ~s(--today must be an ISO date, got "yesterday")
  end

  test "a problem is located at the filter's own line, not the comment's", %{tmp_dir: dir} do
    # `[` is line 1 and the five annotation lines follow, so the tuple is line 7.
    register(dir, @entry)

    assert {output, 1} = run(@script, ["--today", "2027-01-01"], dir)
    assert output =~ ".dialyzer_ignore.exs:7: expired on"
  end

  defp register(dir, entries), do: write(dir, ".dialyzer_ignore.exs", "[\n#{entries}]\n")
end
