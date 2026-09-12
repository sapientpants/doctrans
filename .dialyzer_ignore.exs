# Dialyzer suppression register
#
# Every entry is a narrow `{file, warning_class, line}` key: when the code moves, the
# filter stops matching and `--list-unused-filters` fails the gate, so a suppression
# cannot outlive the line it was written for. File-level class mutes are forbidden —
# they hide warnings nobody has looked at, which is how G02's two wrong diagnoses
# survived. Warnings that carry a column report their location as `{line, column}`;
# use that form, or the filter will never match.
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
  {"lib/doctrans/validation.ex", :pattern_match_cov, {224, 8}},

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
  # rationale: `Pages.create_pages/2`'s `{count, rows}` return is discarded because the
  #   fixture reloads the document with its pages on the next line. Fixable with a
  #   `_ =` binding; left alone here so this register — not a test-support edit — is
  #   what changes in G14.
  {"test/support/fixtures.ex", :unmatched_return, {40, 11}},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: `Sandbox.allow/3` returns `:ok | {:already, …} | :not_found`, all of them
  #   acceptable here — the worker may already hold the connection. Same `_ =` fix as
  #   the fixtures entry, deferred for the same reason.
  {"test/support/worker_helpers.ex", :unmatched_return, 16},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: The stub implements `OpenAIBehaviour` by raising; terminating with an
  #   exception is the behaviour under test, so `no_return` is the correct typing of a
  #   correct function. Both raising callbacks are pinned by line.
  {"test/support/openai_crash_stub.ex", :no_return, 19},

  # owner: @sapientpants
  # expires: 2026-12-12
  # upstream: none
  # rationale: See the entry above — `translate/4` is the second raising callback of the
  #   same stub.
  {"test/support/openai_crash_stub.ex", :no_return, {22, 7}}
]
