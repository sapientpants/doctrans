# Error conventions

Domain operations return `{:error, reason}`, where `reason` is an atom or
`{atom, keyword_bindings}` (see `Doctrans.Errors.reason/0`). For example:

```elixir
{:error, :document_not_found}
{:error, {:query_too_long, [max: 500]}}
{:error, {:http_error, [status: 503]}}
```

Use stable codes for control flow and retry classification. Keep nested failures
structured, for example `{:pdf_extraction_failed, [reason: reason]}`. Normalize
third-party failures with `Doctrans.Errors.normalize/1` or normalize a result with
`Doctrans.Errors.result/1`. Low-level dependency protocols (File, Repo, Oban,
circuit-breaker callbacks) keep their native contracts internally.

Context writes wrap failed Ecto changesets as
`{:error, {:validation_failed, [changeset: changeset]}}`. This preserves field
errors for `to_form/2` without making changesets a separate domain error shape.
Schema changeset builders still return changesets; they are form-building APIs.

Only the web layer turns reasons into user-facing text, using
`DoctransWeb.ErrorMessages.message/1` in the viewing process. Add literal Gettext
messages there, reusing existing message IDs and domains. Unknown reasons get a
generic translated fallback; do not display inspected exceptions or API bodies.
A form can unwrap its changeset and use the standard input error translation.

Background jobs never call Gettext: process-local locales do not follow jobs.
Log diagnostic details with `inspect/1`. The existing document `error_message`
text column is diagnostic storage, populated through `Doctrans.Errors.diagnostic/1`;
it is not displayed by templates and must not become a source of UI translations.
Legacy strings remain readable in that column without a data migration.

Test domain error codes and bindings, web translations (including an error from
another process), and retry behavior when changing error shapes. Run
`mix gettext.extract` after moving or adding messages and `mix precommit` before
finishing a change.

## Test coverage

`mix precommit`, the test pre-commit hook, and CI run `mix test --cover` with
ExCoveralls. CI runs coverage on every pull request and push to `main`, including
configuration-only changes. Tests run once in CI; its pre-commit invocation skips
the coverage hook in favor of the explicit coverage step.

The minimum coverage is 80%, configured in `coveralls.json`; falling below it
fails the command and CI. The same file lists the existing coverage exclusions.
Add meaningful tests for uncovered behavior instead of lowering the threshold or
expanding exclusions. Use `mix coveralls.html` for a local report in `cover/`.

## Static type checks

`mix precommit` runs Dialyzer in the test environment with the project's strict
warning flags, including test support modules. For a focused run, use
`MIX_ENV=test mix dialyzer`. The first run builds the PLT and can take longer;
`MIX_ENV=test mix dialyzer --plt` builds it without running analysis. CI restores
and warms the PLT before analysis, caching it by OS, OTP, Elixir, and dependency
lockfile. Generated `priv/plts/*.plt` and `*.plt.hash` files are ignored by Git.

Add specs to public APIs and use concrete result types. Fix new warnings at their
source before considering a suppression. Existing exceptions live in
`.dialyzer_ignore.exs`; audit stale entries with
`MIX_ENV=test mix dialyzer --list-unused-filters` when changing that file.

## Chat persistence

Each document has one local database conversation (`chat_sessions` and `messages`).
Questions are saved before generation; finalized answers, errors, and bounded retrieval
context are saved when the LiveView receives the result. Reloading restores the latest
100 messages and the last 16 completed history messages. Older messages rotate out on
writes. Retrieval context retains the existing 16-chunk / 32,000-byte limits.
Deleting a document cascades to its conversation and messages.

Streaming tokens and running generation tasks are transient. A reload during generation
may interrupt the answer; the saved question remains visible with a retry notice. The
application does not automatically replay questions. Conversations are shared by tabs
viewing the same document and are refreshed from storage when the viewer mounts.
Opening an idle chat panel also refreshes its history, retrieval context, and retry
notice. Model history uses the last eight complete question/answer pairs, ordered
by answer completion, so overlapping turns from different tabs stay paired.
Messages saved before question links were introduced remain visible, but are
excluded from model history because their pairing cannot be recovered reliably.
