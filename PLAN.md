# Project review and remediation plan

Review date: 2026-09-09

Reviewed revision: `a60fa572440e0e4610f10d47affdbd8bcd5b8024`

Scope: the current project as a whole, with emphasis on critical execution paths.

## Executive summary

The review identified **one High-severity issue and nine Medium-severity issues**.
Nine findings were reproduced with isolated local checks; one was established by
code inspection. No implementation fixes are included in this plan.

The first priority is production's missing PostgreSQL vector configuration, which
breaks page queries. Next are extraction recovery and embedding consistency:
interrupted work can become unrecoverable, and reprocessing can leave chat using
obsolete document content.

The existing suite passed **674 tests with 87.6% measured coverage**. Inspected
safeguards include upload size/content validation, generated storage paths,
sanitized Markdown, parameterized SQL, and transactional chat persistence. The
main gaps are interactions between these components.

## Project overview

Doctrans is a local, single-user document translation and chat application.
Authentication is intentionally absent; deployment binding controls exposure.
Remediation must preserve this architectural constraint.

- **Phoenix LiveView and Bandit:** uploads, dashboard, document viewer, search,
  and chat.
- **PostgreSQL/Ecto:** documents, pages, chunks, conversations, and persistent
  Oban jobs. pgvector and full-text indexes support retrieval.
- **Processing pipeline:** LibreOffice converts non-PDF documents; Poppler
  produces page images; local oMLX models perform OCR, translation, and embedding.
- **Background execution:** Oban handles extraction and translation; supervised
  in-memory tasks generate embeddings and chat responses.
- **Frontend/build:** Tailwind and esbuild. CI uses Elixir 1.20.3/OTP 29, static
  checks, coverage, Dialyzer, and a development Docker build.

Runtime configuration loads process environment values ahead of `.env` defaults.
Docker and production default to loopback exposure.

## Prioritized findings

### F01 — High: Production cannot decode page vector columns

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:** [config/runtime.exs](config/runtime.exs#L45), production repository
  configuration; [lib/doctrans/postgrex_types.ex](lib/doctrans/postgrex_types.ex#L1).

**Problem:** Production never configures `types: Doctrans.PostgrexTypes`, although
dev and test do. Page queries select the embedding column, so production document
viewing and page processing fail even before embeddings exist. The development
Docker setup does not expose this configuration gap.

**Evidence:** A local PostgreSQL connection using the resulting default type
module raised `Postgrex.QueryError`: "type `vector` can not be handled by the types
module Postgrex.DefaultTypes". This occurs even for `SELECT NULL::vector`.
Production configuration was inspected; a deployed release was not started.

**Recommended fix:** Register `Doctrans.PostgrexTypes` in shared repository
configuration.

**Regression test:** Start a repository with production configuration against a
test database and verify page reads plus vector writes.

### F02 — Medium: Partial PDF extraction cannot resume on retry

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:**
  [lib/doctrans/processing/pdf_processor.ex](lib/doctrans/processing/pdf_processor.ex#L115),
  `extract_pages_progressively/4` and `extract_and_create_page/4`.

**Problem:** Every extraction attempt starts at page one and inserts new page
records. Existing pages conflict with the unique document/page-number index.
A restart or extraction failure after partial progress prevents subsequent
attempts from completing the document.

**Evidence:** An injected failure on page two left page one stored. Retrying with
a healthy extractor raised `Ecto.ConstraintError` on page one.

**Recommended fix:** Reuse existing page records and resume missing
extraction/processing work. Adding a changeset constraint alone would only turn
the exception into another failed retry.

**Regression test:** Fail extraction after the first page, retry successfully,
and assert one record and the appropriate processing job per page.

### F03 — Medium: Conversion cleanup removes the input needed for retries

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:**
  [lib/doctrans/processing/document_processor.ex](lib/doctrans/processing/document_processor.ex#L71),
  `do_convert_and_extract/3`.

**Problem:** The original document is deleted after both conversion success and
conversion failure. A failed conversion destroys the input for Oban's next
attempt. Successful conversion followed by PDF extraction failure also leaves
the persisted job pointing to a deleted source file.

**Evidence:** With a synthetic converter returning an error, the first attempt
deleted the source and the second returned `:source_file_not_found`. The document
also remained in `"uploading"` rather than displaying a terminal conversion error.
The successful-conversion/failed-extraction path was established by inspection.

**Impact:** Temporary conversion failures become unrecoverable without uploading
the document again, and the visible status can remain misleading.

**Recommended fix:** Retain retry inputs until page extraction succeeds, or
persist a recoverable converted-PDF checkpoint. Publish terminal conversion
failures to the document status.

**Regression test:** Exercise conversion failure followed by success, and
successful conversion followed by interrupted PDF extraction.

### F04 — Medium: Reprocessing can leave completed embeddings containing obsolete OCR

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:**
  [lib/doctrans/search/embedding_worker.ex](lib/doctrans/search/embedding_worker.ex#L42),
  generation deduplication and `process_page_embedding/3`.

**Problem:** The worker discards generation requests for pages with an existing
task. That task retains its original page snapshot and publishes results without
checking whether the content changed.

**Evidence:** Embedding generation was paused, the page was reset and corrected,
and embeddings were requested again. After the original task was released, the
page contained corrected OCR and reported embeddings `"completed"`, but chunk
search returned the old text.

**Impact:** Reprocessing while embeddings are still running can make chat answer
from superseded content.

**Recommended fix:** Track content revisions, reject stale writes, and retain a
pending regeneration request when content changes during an active task.

**Regression test:** Repeat the controlled race and assert that searchable chunks
and vectors correspond to the latest OCR.

### F05 — Medium: A document can be marked complete before all pages exist

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:** [lib/doctrans/documents/pages.ex](lib/doctrans/documents/pages.ex#L141),
  `all_pages_completed?/1`;
  [document_orchestrator.ex](lib/doctrans/processing/document_orchestrator.ex#L23),
  `check_document_completion/1`.

**Problem:** Completion checks only whether existing page records are incomplete.
They never compare the number of stored pages with `document.total_pages`.
Extraction queues each page immediately while later pages are still rendered,
so early pages can finish processing before the remaining records exist.

**Evidence:** A document declaring three pages was marked `"completed"` when only
its completed first page existed.

**Impact:** Progress is misleading, and premature completion affects recovery:
startup page recovery selects documents whose status is `"processing"`.

**Recommended fix:** Require all expected pages to exist and satisfy the
completion policy before changing document status.

**Regression test:** Complete page one while extraction of later pages is blocked;
the document must remain incomplete.

### F06 — Medium: Reprocessing silently ignores selected models

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:** [lib/doctrans/processing/worker.ex](lib/doctrans/processing/worker.ex#L79),
  `queue_page_reprocess/2`;
  [llm_processing_job.ex](lib/doctrans/jobs/llm_processing_job.ex#L26), `perform/1`.

**Problem:** `queue_page_reprocess/2` stores model choices as top-level job
arguments. `LlmProcessingJob.perform/1` reads only a nested `"opts"` argument;
otherwise it passes an empty options list.

**Evidence:** A job selecting a translation model was persisted and executed.
The argument survived database serialization, but the translator received `[]`.
Extraction model selections follow the same broken path.

**Impact:** Users repeat processing with the default models despite choosing
alternatives.

**Recommended fix:** Decode the persisted model fields into the keyword options
expected by `LlmProcessor`.

**Regression test:** Enqueue and execute a real reprocessing job, asserting both
selected models reach their respective API calls.

### F07 — Medium: Multi-query retrieval discards relevant chunks from the same page

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:** [lib/doctrans/chat/multi_search.ex](lib/doctrans/chat/multi_search.ex#L79),
  `merge_with_rrf/2`.

**Problem:** Search now returns chunks, but rank fusion still groups results
solely by `page_id` and retains one result per page. Distinct chunks are treated
as duplicates, and their rank contributions are combined into the retained chunk.

**Evidence:** A fixture with three relevant chunks on one page returned all three
through direct search but only one through multi-query retrieval.

**Impact:** Questions requiring several facts from a dense page lose available
evidence before answer generation.

**Recommended fix:** Fuse by chunk identity, using the same page/chunk distinction
as `Chat.merge_context/3`.

**Regression test:** Retrieve several distinct chunks from one page through
multiple queries; retain each chunk once without inflating scores.

### F08 — Medium: The LLM circuit breaker records failures but does not gate requests

- **Confidence:** High.
- **Evidence type:** Code inspection.
- **Location:** [lib/doctrans/processing/openai.ex](lib/doctrans/processing/openai.ex#L136),
  request dispatch and `handle_api_error/2`.

**Problem:** The client melts `:openai_api` after failures, but extraction,
translation, and chat never check that circuit before making requests.
Repository-wide inspection found `CircuitBreaker.call/2` used only by the
embedding worker.

**Impact and trigger:** During an LLM outage, an open circuit does not stop further
requests. Request retries and processor retries continue occupying the single
LLM processing queue despite the reported breaker state.

**Recommended fix:** Gate LLM requests through the breaker and ensure each
classified failure is counted once.

**Regression test:** Open the circuit and assert extraction, chat, and streaming
return `:circuit_open` without contacting a local HTTP stub.

### F09 — Medium: Newly extracted pages do not appear in an already-open empty viewer

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:**
  [lib/doctrans_web/live/document_live/show.ex](lib/doctrans_web/live/document_live/show.ex#L230),
  the `:page_updated` handler.

**Problem:** Page updates replace `current_page` only when it already exists and
has the incoming page's ID. Opening a document before its selected page is created
leaves `current_page` nil, so subsequent updates for that page are ignored.

**Evidence:** The LiveView reproduction remained empty after page creation and
its completion broadcast. Selecting the same page manually made the content
appear.

**Impact:** Progressive viewing requires unnecessary navigation or reloading when
the selected page did not exist at mount or selection time.

**Recommended fix:** Accept updates matching the selected document and page
number, including when `current_page` is nil.

**Regression test:** Mount before page creation, broadcast the new page, and
assert the image/content appear without navigation.

### F10 — Medium: A single refined search query is ignored

- **Confidence:** High.
- **Evidence type:** Reproduced.
- **Location:** [lib/doctrans/chat.ex](lib/doctrans/chat.ex#L258), `retrieve/4`.

**Problem:** When `queries` contains one entry, `Chat.retrieve/4` searches
`standalone_question` instead of that entry. The grader can legitimately return
one refined query, so refinement repeats the original search rather than looking
for the missing information.

**Evidence:** A mock recorded the original question being embedded despite a
different single refined query being supplied.

**Impact:** Refinement can repeatedly miss information that the grader has
identified a specific query to retrieve.

**Recommended fix:** Search the supplied query in the single-element case; use
the original question only when no query is supplied.

**Regression test:** Have the grader propose one distinct query and assert
retrieval embeds that exact query.

## Needs verification

These are unverified operational risks, not demonstrated exploits or additional
established findings.

- **Native PDF resource limits:**
  [PdfExtractor](lib/doctrans/processing/pdf_extractor.ex) invokes Poppler through
  `System.cmd/3` without a deadline. Pathological PDFs and resulting CPU, memory,
  or disk consumption were not exercised or measured.
- **Embedding load:** [EmbeddingWorker](lib/doctrans/search/embedding_worker.ex)
  starts a task per page without a global concurrency bound. Its practical effect
  on a busy local inference server needs measurement.

## Validation performed during the review

| Check | Result |
| --- | --- |
| `mix test --cover` | 674 passed; 87.6% coverage |
| Temporary reproduction harness | Nine defect cases confirmed |
| `mix compile --warnings-as-errors --all-warnings` | Passed |
| `mix format --check-formatted --no-compile` | Passed |
| `mix credo --strict` | Passed |
| `mix sobelow --config --private` | Four low-confidence SQL warnings reviewed as parameterized queries |
| `mix dialyzer --no-compile --no-check` | Passed using the existing PLT and repository filters |
| `elixir scripts/check_translations.exs` | Passed |
| `elixir scripts/check_module_size.exs --max-lines 600` | Passed |
| `git status --short` | Clean at the end of the review |

Tests used the local test database, synthetic fixtures, and mocked or overridden
AI endpoints. Initial Mix execution was blocked by sandbox TCP restrictions;
authorized reruns succeeded. The full suite emitted background-task/sandbox
teardown errors despite passing. Dialyzer excluded 45 warnings using existing
repository filters; its PLT freshness check was skipped.

The temporary reproduction harness asserted the presence of each defect. Its
passing result confirms the defects; it does not indicate they were fixed. The
local review artifacts were:

- `/tmp/doctrans_project_review_test.exs`
- `/tmp/doctrans-project-review-repros.log`
- `/tmp/doctrans-project-review-tests.log`

These artifacts are outside the repository and may not survive temporary-file
cleanup. The findings and regression scenarios above preserve their essential
evidence.

The complete `mix precommit` alias was not run during the read-only review because
it includes lockfile mutation. Its safe local checks were run individually.
Dependency advisory refresh, Docker/release execution, and real-model integration
were not performed during that review.

### Validation after recording this plan

On the documentation branch `review/project-findings`, `mix precommit` completed
successfully: 674 tests passed with 87.6% coverage, and the dependency advisory
audit reported no vulnerabilities. Markdownlint also passed with no errors.
The only repository change was this plan; the findings remain unresolved.

## Recommended next steps

### Immediate fixes

- [x] **F01:** Configure production vector decoding and add a production
  configuration smoke test.
- [x] **F02:** Make partial PDF extraction resumable without duplicate pages.
- [x] **F03:** Preserve conversion retry inputs and publish terminal failures.

### Correctness and reliability follow-ups

- [x] **F04:** Prevent stale embedding writes and retain regeneration requests.
- [x] **F05:** Require all expected pages before completing a document.
- [x] **F06:** Preserve selected models through persisted job execution.
- [ ] **F07:** Fuse retrieval results by chunk identity.
- [ ] **F08:** Enforce circuit rejection before LLM requests.
- [ ] **F09:** Populate the selected viewer page when it is created after mount.
- [ ] **F10:** Use a single refined query when supplied.

### Longer-term improvements

- [ ] Measure native PDF extraction resource use and establish appropriate limits.
- [ ] Measure embedding concurrency against the local inference server and bound
  work where needed.
- [ ] Extend integration coverage across persisted job arguments, partial
  execution, concurrent reprocessing, and production configuration.
- [ ] Run a release smoke test.
- [x] Run a current dependency advisory audit while preparing this plan
  (2026-09-09); the scanner reported no vulnerabilities.

For each implementation change, add the relevant regression coverage and run
the repository's required `mix precommit` checks. Preserve the local, single-user
deployment model; none of these findings requires adding authentication.

## Review coverage and limitations

The review inspected repository guidance, README and architecture documentation,
manifests, configuration, migrations, CI/build definitions, core processing and
recovery, upload/deletion boundaries, search, chat persistence, LiveView flows,
sanitization, and relevant tests.

It did not exhaustively inspect every presentation component, locale translation,
or dependency implementation. No production services, real document corpus,
deployed release, or live oMLX installation were exercised. Dependency versions
were inspected, and the later advisory scan reported no known vulnerabilities;
this is not an exhaustive dependency security review.
