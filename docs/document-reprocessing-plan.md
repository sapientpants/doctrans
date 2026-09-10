# Whole-document reprocessing plan

Status: implemented on this branch; see the PR for validation results.
Branch: `plan/document-reprocessing`.

## Intended outcome

Retain the original uploaded file and add **Reprocess document** to the document
detail page. Reprocessing runs the complete pipeline with the current processing
code: office-to-PDF conversion where applicable, fresh page rendering, markdown
extraction, translation, chunking, and embeddings. It must not reuse an old
converted PDF or old page images, so improvements at every stage take effect.

Match first-time import UX: confirmation, queued state, live progress from 0%,
progressive page availability, and completion/error feedback on both the dashboard
and detail view. There is no new file transfer during reprocessing.

Preserve document identity, URL, title, original filename, target language, and
chat history. Replace generated pages and search data. Page count/layout may
change when a newer converter renders the original upload differently. Existing
chat answers remain historical; generated page/chunk citations may become stale.
The confirmation must explain replacement and processing time. No restore of the
previous generated version is included in the first implementation.

## Existing code and required changes

| Area | Current behavior | Planned change |
| --- | --- | --- |
| `processing/document_processor.ex` | Converts office files and deletes source after success | Retain source and reconvert it for each explicit new run |
| `processing/pdf_processor.ex` | Deletes PDF; retries reuse pages/images and skip completed pages | Preserve uploaded PDF; keep retry reuse within a run, start explicit reprocessing with fresh derived output |
| `jobs/document_extraction_job.ex` | Recovery prefers `original.pdf` | Resolve the actual original upload first, so office uploads are reconverted |
| `processing/worker.ex` | Queues extraction and page jobs; cancellation excludes executing/suspended jobs | Reuse queues and guard overlapping runs; cancellation alone is insufficient |
| `processing/startup_recovery.ex` | Recovers documents and unfinished page jobs | Preserve source, run identity, and chosen models during recovery |
| `documents/progress.ex` | Completed extraction/translation steps determine progress | Reuse for both first import and reprocessing |
| `document_live/components.ex` | Dashboard card has processing bar | Share progress UI with detail view and include queued state |
| `document_live/reprocess_modal.ex` | Single-page model picker; reset/enqueue are separate | Extend scope and use safe transactional entry points |
| `search/embedding_worker.ex` | Guards writes with page content revisions | Preserve guards and test deletion/replacement during old embedding work |

Paths above are under `lib/doctrans/` except `document_live/`, which is under
`lib/doctrans_web/live/`.

## 1. Retain and resolve the original upload

- Keep the exact uploaded bytes at the existing fixed
  `<document directory>/original<validated extension>` path until document deletion.
- Remove successful original-upload deletion in both document/PDF processors.
  Audit cancellation branches too: stopping processing must not delete the source.
  Preserve cleanup of failed upload creation and intentional document deletion.
- Resolve the original by its stored validated extension, never by preferring an
  available converted PDF. Centralize resolution for jobs, recovery, and eligibility.
  Browser events supply a document ID, never an arbitrary source path.
- Separate original storage from derived conversion/rendering output. Converters
  write into a run-specific directory, never overwrite the retained original.
- Existing successfully imported documents have already lost their source. Disable
  whole-document reprocessing with a clear re-upload explanation. A converted PDF
  alone does not qualify as the original office upload. Keep page reprocessing.
- Document retention and disk-space implications in README, and update
  `docs/FILE_PATH_AUDIT.md`. No automatic deletion of original uploads by age.

## 2. Add an explicit processing run identity

Add a migration and internal schema fields for a processing run ID and selected
extraction/translation models on the document (schema currently `documents/book.ex`).
Keep these fields out of general attribute casting. New imports and explicit
reprocessing create a run; retries and recovery keep that same run ID.

### Model selection and result provenance

- Let users choose extraction and translation models in the document reprocessing
  confirmation, preselected from configured defaults. Keep the existing single-page
  model picker. Initial uploads continue using configured defaults; adding upload
  model selectors is outside this change.
- Resolve defaults to explicit model identifiers when creating a run and persist
  them on the document with its run ID. Pass these exact choices into jobs so a
  configuration change or restart cannot silently change models midway through
  the run. These fields describe the current run, not an archive of previous runs.
- Add nullable `extraction_model` and `translation_model` fields to pages for the
  models that produced their current results. Persist the effective request model
  together with each successful stage's content/status in the same guarded write.
  Keep fields out of general attribute casting. Job arguments alone are not the
  durable source of this information because job records may be pruned.
- Distinguish requested models from provider-reported identity: the page fields
  record the exact identifier sent to the API. The current processor contract
  returns text only, so provider-reported canonical identity is not recorded.
  A mutable model alias does not identify an immutable set of model weights.
- A single-page override updates only that page's successful stage provenance;
  the document's run choices remain unchanged. Failed attempts must not be labeled
  as models that produced a result. Clear provenance when its content is reset,
  and retain provenance for stages reused on retry. Translation skipped for empty
  extracted text has no translation model because no translation call occurred.
- Existing page results remain NULL/"Unknown" after migration. Do not infer their
  models from current configuration or incomplete historical jobs. Legacy work
  can record the effective model when it next successfully produces new content.
- Show the current run's selected models and the selected page's result models in
  document/page details, making overrides and unknown values visible. This scope
  covers extraction and translation; embedding model selection/provenance is a
  separate concern and must not be implied by these fields.

Store derived files under a path such as
`<document directory>/runs/<run ID>/`, with converted PDF and page images inside.
The original upload remains outside this directory. Use existing relative image
paths for serving files, and review directory assumptions in extractor/converter,
image serving, deletion, and sweeper code.

Pass document/run identity through extraction and page jobs. Check that the run
is still current before stage writes, page creation, enqueueing, error/completion
updates, and broadcasts. Do not hold database locks across external conversion,
rendering, or model calls. Enforce the current-run check with each database mutation,
not just at job start. Old jobs should terminate as obsolete without changing the
new run. Audit legacy jobs without run IDs and define migration compatibility:
allow them only for documents not yet assigned a run; once a new run exists they
must not mutate it.

This separates two operations cleanly: retries reuse partial output within the
same run, while an explicit reprocess uses a fresh directory and fresh pages.

## 3. Make starting reprocessing atomic

Add `Doctrans.Processing.DocumentReprocessing.reprocess_document(document_id, opts)`.
Return success only after commit, or structured errors using existing error and
web-message conventions. Validate model selections and original-file readability
before clearing results; do not make model API calls inside the transaction.

Allow completed or errored documents with their original upload present. Reject
uploading/queued/extracting/processing documents and active extraction/LLM jobs in
available, scheduled, executing, retryable, or suspended states. Revalidate from
the database on every submission, including stale modals and duplicate tabs.

In one repository transaction:

1. Lock the parent document, then affected pages in deterministic order; recheck
   eligibility and active jobs.
2. Generate the new run ID and store selected models. Set status to `queued`, clear
   error_message, and reset total_pages to unknown until freshly rendered.
3. Delete old generated page rows and their chunks through verified cascade
   behavior. New pages receive new IDs; document identity remains stable. Full-text
   and semantic search must immediately stop returning old generated content.
4. Insert exactly one `DocumentExtractionJob` for the actual original upload and
   new run. Treat Oban `conflict?` as failure even when insertion returns `{:ok, job}`.
5. Roll back every database change on insertion failure/conflict. No notification
   or filesystem deletion occurs before commit.

Do not delete old files inside the transaction. After commit, enqueue idempotent
cleanup of superseded run directories, with retries. Cleanup must never touch the
original or current run. Handle legacy page/converted-file paths explicitly and
use fixed allowed paths, not filename-derived broad deletion. Empty fresh output
directories can be created by the worker after it verifies run ownership.

## 4. Run the existing pipeline from the beginning

- For office uploads, always convert the original into the new run directory;
  for PDFs, render from the retained original PDF.
- With no current page rows/images in the new run, the existing progressive
  extraction loop must render every page and create fresh page records.
- Queue extraction and translation for every new page, carrying chosen models
  and current run identity. Normal document/page priorities apply; explicit
  single-page requests can retain their existing higher priority.
- Preserve retry behavior within a run: reusing its successful conversion/page
  output is acceptable on retry. Do not regenerate completed work on every retry.
- Recovery must use the actual original upload and current run directory/models,
  including after job discard/removal. Prevent recovery from generating another
  run or accidentally choosing a previous conversion result.
- Mark queued → extracting → processing → completed/error consistently. Because
  rendering and page processing overlap, completion must require fresh total_pages
  and all expected current-run pages. Guard final status writes by run identity.
- Leave chunking and embeddings on the existing downstream pipeline. Verify old
  embedding tasks tolerate page deletion and cannot publish stale results.

## 5. Coordinate competing actions

Apply a consistent parent-document-first locking protocol to reprocessing,
relevant enqueue paths, recovery, completion, and deletion. Move the current
single-page reset/enqueue into one transaction and check insertion failures; it
currently ignores enqueue errors and publishes reset before queue success.

Tighten page eligibility: extraction-completed does not imply translation is idle.
Reject page actions while the document is being restarted or that page has active
work. Old page IDs from a previous run return a clean stale/not-found result.
Run guards are defense against late results, not a reason to allow routine
reprocessing of an actively running document.

Audit chat persistence and citation foreign keys before choosing page deletion
constraints. Preserve messages; optional references to removed generated rows must
be nullable or represented historically. Do not cascade-delete chat history.

## 6. Match initial-import progress and confirmation UX

- Add `#show-document-reprocess` in the detail header, separate from the page action.
  Generalize the function-component modal helper with explicit page/document scope,
  distinct document form/submit IDs, and existing model selectors.
- Confirmation names the document, explains full conversion/rendering/processing
  and replacement, and has loading/disabled submission plus specific error states.
  Cancellation before submit changes nothing.
- After successful submission, close the modal, remain on the detail page, clear
  old page content/thumbnails, and show queued progress. Reset the dashboard too.
- Share progress components for initial imports and reprocessing. Show 0% while
  queued, an indeterminate preparation state while page count is unknown, then
  extraction/translation progress using `Documents.Progress.calculate/2`.
  Do not invent a percentage for conversion or file transfer.
- Show useful stage/page counts; make freshly processed pages readable as they
  arrive. Reconcile the selected page number with the newly discovered page count
  and show a waiting state before that page exists.
- Preserve progress through reloads, reconnects, navigation, and multiple tabs by
  deriving it from persisted state. Include queued status in progress visibility.
  Show indexing readiness separately from extraction/translation progress.
- Preserve current completion semantics, including terminal extraction errors;
  show errors honestly instead of forcing a misleading successful 100%.
- Publish one lightweight document-reset event after commit, plus normal document
  updates. Detail subscribers refetch current state and clear obsolete content.
  Continue/coalesce page updates; do not send all markdown or retain a full page
  collection in sockets. Ignore notifications belonging to superseded runs.
- Stop in-flight chat answers when reset is received and refresh retrieval readiness.
  Saved messages stay historical; new questions use current generated content.
- Use `to_form`, `<.form>`, `<.input>`, `<.icon>`, Tailwind/custom CSS, accessible
  dialog/progress labels and focus handling, and translated text. No authentication,
  extra HTTP library, or LiveComponent is needed.

## 7. Verification plan

Add focused document-reprocessing service tests and a separate race test file where
independent database connections are needed. Extend existing processor, converter,
recovery, embedding-race, and LiveView tests.

1. Source retention: exact PDF/office bytes survive import, retries, reprocessing,
   and cancellation; deleting a document still removes all files. Legacy missing
   originals and office uploads with only a converted PDF reject clearly.
2. Full rerun: stub conversion/rendering with visibly different second-run output;
   verify conversion runs again, every page image is regenerated, page count can
   change, and extraction/translation/search all use the new content.
3. Transaction: successful restart creates one job and resets derived DB state;
   invalid options, missing source, busy state, every active job state, insertion
   failure, and uniqueness conflicts leave previous results/jobs unchanged.
4. Recovery: crash before execution and during conversion/rendering/page processing;
   resume the same run with original source and chosen models, no duplicate pages
   or jobs. New-run behavior differs from within-run retry reuse.
5. Races: duplicate submits, page actions, recovery, deletion, old extraction/LLM
   results, completion observations, and old embedding responses cannot mutate a
   newer run. Legacy jobs without run IDs cannot bypass the guard.
6. Cleanup: rollback never deletes files; post-commit cleanup retries safely,
   preserves original/current output, and handles legacy layouts.
7. UI: stable-ID `element/2`, `has_element?/2`, and `render_submit/2` assertions for
   modal scope/cancel/errors, queued and unknown-count states, 0/intermediate/100%
   progress, honest failures, fresh thumbnails, changed page count, cross-tab
   updates, reload continuity, and progressive readability.
8. Regression: initial imports, single-page custom models, historical chat, citation
   handling, deletion, and large-document bounded socket state remain correct.
9. Model provenance: configured defaults are snapshotted at run creation; changed
   configuration, retries, recovery, and job pruning cannot alter/erase provenance.
   Successful stages save content and model together; failed or stale responses
   cannot overwrite either. Test page overrides, stage reset, empty-content
   translation skips, provider-reported aliases if supported, legacy unknown
   values, and the distinction between document choices and page result models.

Read Mix task help before new task invocations. Run focused tests, then
`mix precommit` and resolve failures. Manually compare first import and full rerun
for a multi-page PDF and an office document, including an updated converter result.

## Delivery stages and acceptance

Implement source retention/resolution first; then run identity and atomic restart;
then pipeline/recovery guards and cleanup; then modal/progress integration and
regression verification. Document retention and legacy-source limitations.

Done means one confirmation reruns every stage from the original uploaded bytes,
uses current processing improvements, reports progress like initial import, and
cannot mix old generated content or late results into the new document run.
Users can select both processing models and inspect which model produced each
page's current extraction and translation results.
