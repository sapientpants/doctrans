# Dialyzer suppression register
#
# Every entry is a narrow `{file, warning_class, line}` key: when the code moves, the
# filter stops matching and `--list-unused-filters` fails the gate, so a suppression
# cannot outlive the line it was written for. File-level class mutes are forbidden —
# they hide warnings nobody has looked at, which is how G02's two wrong diagnoses
# survived. Always give the location as a bare line number: dialyxir 1.4.8 normalises a
# warning's position to its line before matching filters, so a `{line, column}` filter
# can never match (jeremyjh/dialyxir#584).
#
# Each entry carries four comment keys, enforced by scripts/check_dialyzer_filters.exs:
#
#   owner      GitHub handle answerable for the entry
#   expires    ISO date; the gate fails once it passes, so the entry is re-decided
#   upstream   issue/PR URL, or `none` when the cause is first-party
#   rationale  what the warning is and why suppressing it is the right call
#
# The register is capped at 8 entries. Adding the ninth means raising the cap on
# purpose rather than growing the file by reflex.

[
  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: `sanitize_title/1`'s `%{} = attrs` clause is unreachable because every
  #   caller path validates `:title` as a binary first. It is kept as a defensive
  #   fallback for a private pipeline; the alternative is a FunctionClauseError if the
  #   validation order ever changes. Re-decide at expiry: delete the clause or keep it.
  {"lib/doctrans/validation.ex", :pattern_match_cov, 243},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: `use Gettext.Backend` generates a call to `Gettext.Plural.plural/3` with
  #   the `Expo.PluralForms.plural_ast/0` opaque term inlined from the compiled .po
  #   headers. The warning is in generated code at line 1, three times (one per plural
  #   form in priv/gettext); nothing in this repository can annotate it. No upstream
  #   issue was found; recheck after the next gettext/expo bump before filing one.
  {"lib/doctrans_web/gettext.ex", :call_without_opaque, 1},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: The stub implements `OpenAIBehaviour` by raising; terminating with an
  #   exception is the behaviour under test, so `no_return` is the correct typing of a
  #   correct function. Both raising callbacks are pinned by line.
  {"test/support/openai_crash_stub.ex", :no_return, 21},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: Same case as the entries below, in the stub that supersedes a page and
  #   then crashes: the crash is the scenario, so `extract_markdown/2` terminating only
  #   with an exception is the correct typing of a correct function.
  {"test/support/superseding_crash_stub.ex", :no_return, 23},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: See the entry above — `translate/4` is the second raising callback of the
  #   superseding stub.
  {"test/support/superseding_crash_stub.ex", :no_return, 29},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: See the entry above — `translate/4` is the second raising callback of the
  #   same stub.
  {"test/support/openai_crash_stub.ex", :no_return, 24}
]
