# Doctrans improvement plan

Status: implementation in progress; C01 completed.
Base: `main` at `6953656`, reviewed on 11 September 2026.
Branch: `plan/project-improvements`.

The README describes a local, single-user application for translating documents with local AI,
then searching and chatting over the results. Prioritize faithful output, recoverable processing,
trustworthy retrieval, and a usable viewer. Preserve the deployment model: do not add authentication
or authorization. Document content stays local only when the configured inference endpoint is local.

The review covered processing, recovery, jobs, database schemas and migrations, search, chat,
LiveViews, assets, configuration, Docker, CI, tests, and development tooling. The reviewed code
matches the tree pulled from main. Findings below distinguish reproduced behavior from code-based
risks. Real-model translation quality, large-library performance, and browser accessibility still
need dedicated validation.

The review baseline passed `mix precommit`: 745 tests and 88.7% reported coverage. That percentage
excludes several critical workers; the passing run also logged background-task database ownership
errors. Passing checks therefore do not resolve the findings in this plan.

Priority: P1 means incorrect document content, answers, or success reporting; P2 means reliability,
workflow, or verification defects; P3 means secondary usability and maintenance improvements.

## Implementation rules and order

- Use small changes with focused acceptance tests. Check the current code before each item.
- Start with warning enforcement, then content correctness and processing recovery.
- Make indexing durable before expanding search features or adding a retry/status interface.
- Complete viewer and upload fixes before larger product additions.
- Use the existing Req client, Oban, LiveView async/stream APIs, and shared form/icon components.
- Keep the current revision checks, retained originals, image-serving restrictions, and bounded chat context.
- Run relevant tests and `mix precommit` after each implementation batch; resolve failures before proceeding.
- Update translations and README behavior descriptions alongside user-visible changes.
- Keep optional product additions separate from confirmed defect fixes.

## Phase 1 — Faithful document content and answers

- [x] **C01 · P1 · Align source and translated retrieval chunks.**
  Original and translated Markdown are independently grouped by word count, then paired by chunk index.
  Translation expansion or contraction shifts boundaries, attaching unrelated translations to source embeddings.
  A probe produced source chunks `[assets + liabilities, cash]` and translations `[assets, liabilities, cash]`;
  the cash result consequently contained the liabilities translation.
  Use aligned segments, or retrieve the actual embedded source content until reliable alignment exists.
  Apply the same strategy to normal indexing and the maintenance rechunk task.
  Acceptance: expansion/contraction fixtures retain every passage and never pair unrelated source/translation text;
  chat context contains the passage retrieved by the vector search.
  Implemented: source-only chunks in normal indexing and maintenance rechunking; retrieval ignores
  legacy chunk translations and chat uses source text for saved chunk context. Whole-page fallback
  retains its full translation. Expansion/contraction regression tests cover both indexing paths,
  passage preservation, vector retrieval, and legacy chat context. Existing vectors need no rebuild;
  README documents optional rechunking to remove stored legacy pairings.
  Evidence: `lib/doctrans/search/embedding_worker.ex:215,262`, `lib/doctrans/chat.ex:141`,
  `lib/mix/tasks/rechunk_documents.ex`. Reproduced with a chunking probe.

- [x] **C02 · P1 · Reject incomplete or reasoning-only document output.**
  The shared API response parser ignores `finish_reason` and substitutes reasoning when final content is missing.
  OCR and translation can therefore persist truncated text or model reasoning as completed document content.
  Existing tests explicitly accept partial output with `finish_reason: length` and reasoning-only responses.
  Require usable final content and validate completion; retry with a suitable output budget or segmentation,
  or return an actionable incomplete-output error. Review streaming completion separately for chat.
  Acceptance: truncated and reasoning-only OCR/translation never become completed/indexed text;
  valid final responses still work; provider compatibility is covered by representative response fixtures.
  Implemented: non-streaming responses require explicit `finish_reason: stop` and non-empty
  final text after removing leading, unfenced thinking blocks and response code fences.
  Literal thinking tags within final document text and code examples are preserved.
  Missing/unknown completion markers,
  truncation, filtering, tool calls, reasoning-only output, and unclosed thinking blocks return
  `incomplete_output`, with recovery guidance in the UI and no immediate unchanged-request retries.
  HTTP/database regression fixtures cover OCR and translation persistence and final-content variants.
  Streaming review: chat uses a separate SSE collector that ignores finish reasons and the DONE marker;
  it can still accept a disconnected/truncated stream. Stream completion tracking and partial-answer
  presentation remain a separate chat follow-up; this change covers non-streaming calls only.
  Evidence: `lib/doctrans/processing/openai.ex:154,177`,
  `test/doctrans/processing/openai_request_test.exs:299,336`. Confirmed by code and existing tests.

- [ ] **C03 · P1 · Separate successful completion from failed pages and pending retries.**
  `all_pages_completed?/1` counts extraction errors as completed, including failures awaiting Oban retries.
  Another page finishing can overwrite an error document with `completed`.
  Require successful required stages for success; represent partial failure explicitly and preserve errors
  until retry outcomes justify changing the document state.
  Acceptance: a failed OCR page plus a successful page never produces a successful document;
  scheduled retries remain distinguishable from terminal failure; a successful retry reconciles status.
  Evidence: `lib/doctrans/documents/pages.ex:156`,
  `lib/doctrans/processing/document_orchestrator.ex:50`, `lib/doctrans/processing/llm_processor.ex:220`.
  Reproduced in a database test using a rolled-back transaction.

- [ ] **C04 · P1 · Invalidate stale chat context after single-page reprocessing.**
  Whole-document reprocessing clears saved retrieval context; single-page reprocessing does not.
  Saved context lacks page revisions, and merging retains the higher-similarity copy even when it is obsolete.
  A probe merging corrected `Assets are 100` into higher-ranked old `Assets are 10` retained the old value.
  Carry source revisions through retrieval and persistence, remove obsolete context, and prevent in-flight
  answers from being saved as current when a supporting page generation changes.
  Acceptance: correcting a page updates the next answer after reload and in another open tab;
  an in-flight answer based on the old page cannot restore obsolete context.
  Evidence: `lib/doctrans/processing/document_reprocessing.ex:59`, `lib/doctrans/chat.ex:179`,
  `lib/doctrans/chat/conversations.ex:15,79`. Merge behavior reproduced; persistence gap traced.

## Phase 2 — Recoverable processing and indexing

- [ ] **R01 · P2 · Move indexing to durable, bounded jobs.**
  Embedding requests and pending work exist only in a GenServer and supervised tasks.
  Startup recovery does not recover indexing for fully translated pages. Restart, task failure, or exhausted
  retries can leave completed documents unavailable to semantic search/chat until manually reprocessed.
  Use Oban with page-generation-aware uniqueness, bounded concurrency, and pending/error reconciliation.
  Acceptance: restart during indexing eventually restores search/chat; transient failure retries persist;
  duplicate requests do not create duplicate work; obsolete generations cannot overwrite current vectors.
  Evidence: `lib/doctrans/search/embedding_worker.ex:37,46`,
  `lib/doctrans/processing/startup_recovery.ex:67`. Code-based finding.

- [ ] **R02 · P2 · Track failed page embeddings accurately.**
  Successful chunk embeddings are followed by a page embedding call whose failure is only logged;
  the page is then marked indexed. Global search relies on page embeddings and silently loses semantic coverage.
  Track/retry page indexing separately, or standardize global search on chunk retrieval.
  Acceptance: chunk success plus page embedding failure cannot report complete global indexing;
  retry restores semantic search without rerunning OCR/translation.
  Evidence: `lib/doctrans/search/embedding_worker.ex:151,320`. Implement with R01.

- [ ] **R03 · P2 · Reconcile document completion on replay and restart.**
  The last translation is saved before document completion is updated. A crash between those writes leaves
  a processing document whose resumed job skips completed stages and whose pages startup recovery excludes.
  Recheck completion on every successful replay and reconcile eligible documents during startup.
  Acceptance: a processing document with all final pages saved reaches the correct terminal state after
  job replay or startup, without making another model request. Cover failed pages using C03's status semantics.
  Evidence: `lib/doctrans/processing/llm_processor.ex:121,245,257`,
  `lib/doctrans/processing/startup_recovery.ex:26,68`. Reproduced in a rolled-back database test.
  Dependency: C03.

- [ ] **R04 · P2 · Bound PDF subprocess execution and resources.**
  `pdfinfo` and `pdftoppm` run through unbounded `System.cmd`; the extraction job has no deadline,
  and extraction concurrency is one. A hung renderer can occupy the only slot indefinitely.
  Reuse the monitored LibreOffice subprocess approach with deadlines, bounded diagnostics, child cleanup,
  and configurable page/image resource limits.
  Acceptance: a fake hung renderer times out and is reaped; subsequent extraction can run;
  excessive diagnostic output is bounded; legitimate larger documents have actionable limit errors.
  Evidence: `lib/doctrans/processing/pdf_extractor.ex:94,117`, `config/config.exs:104`.
  Code-based finding; no deliberate renderer hang was run during review.

- [ ] **R05 · P2 · Use one runtime storage root for writing and serving images.**
  Writers use `Config.Uploads.upload_dir/0`, but the endpoint always serves `priv/static/uploads`.
  Custom storage can successfully process documents while returning broken page-image URLs.
  The default root is also expanded during build configuration, which complicates portable releases.
  Resolve the runtime data directory consistently and retain the generated-image-only serving restrictions.
  Acceptance: upload, view, reprocess, restart, and delete work with a nondefault data root;
  originals and converted PDFs remain inaccessible through HTTP; image responses retain no-store headers.
  Evidence: `lib/doctrans_web/endpoint.ex:46`, `config/config.exs:47`.

- [ ] **R06 · P2 · Give retries and circuit breakers clear ownership.**
  EmbeddingWorker melts the breaker around a client that already classifies and melts failures.
  Transient errors can count twice, and permanent errors can count through the outer wrapper.
  Remove duplicate accounting and reconcile Req, processor, and Oban retry policies into documented bounds.
  Acceptance: one transient operation failure counts once; permanent API errors do not open the circuit;
  permanent failures do not receive ordinary transient job retries; cancellation does not wait through
  unnecessary nested sleeps. Preserve existing error-code conventions.
  Evidence: `lib/doctrans/search/embedding_worker.ex:282`, `lib/doctrans/processing/openai.ex:480`.
  Coordinate with R01.

## Phase 3 — Search relevance and responsiveness

- [ ] **S01 · P2 · Share query embeddings and run search asynchronously.**
  Search synchronously generates separate embeddings for count and results. Direct disconnected/connected
  mounts repeat the work, producing four inference calls on the successful initial-load path.
  The loading state cannot render while the callback blocks.
  Use one combined asynchronous operation on the connected mount, reuse its vector, and discard stale results.
  Acceptance: one query embedding per submitted query; loading is visible while inference waits;
  navigation remains responsive; older responses cannot replace newer results; count and results agree.
  Evidence: `lib/doctrans_web/live/search_live.ex:32`, `lib/doctrans/search.ex:66,247`.

- [ ] **S02 · P2 · Distinguish retrieval outages from no matches.**
  MultiSearch discards failed requests and returns success with no results even when every query fails.
  Global keyword search also depends on successful embedding generation.
  Return an error when no query succeeds, retain partial successes, and support keyword-only global search
  while inference is unavailable. Present the degraded mode and errors accurately.
  Acceptance: all-query failure is an outage, successful empty retrieval is no matches, partial success
  remains useful, and known keyword results are available without an embedding server.
  Evidence: `lib/doctrans/chat/multi_search.ex:53`, `lib/doctrans/search.ex:66`.
  An all-`:circuit_open` probe returned `{:ok, []}`.

- [ ] **S03 · P2 · Filter semantic relevance before rank fusion.**
  Global semantic retrieval has no similarity floor. With reciprocal-rank constant 60 and score floor .01,
  the top 40 semantic-only pages qualify regardless of actual similarity.
  Calibrate a similarity threshold before combining ranks, using known-answer and unrelated-query examples.
  Acceptance: unrelated queries can return no results; known keyword and semantic matches retain recall;
  pagination/count use the same filtering. Measure query plans on a representative larger library before
  deciding whether bounded candidate retrieval or index changes are needed.
  Evidence: `lib/doctrans/search.ex:57,313`.

- [ ] **S04 · P2 · Split oversized paragraphs consistently.**
  A long paragraph is split only when no preceding text is accumulated; after an introduction it becomes
  an oversized chunk. A probe yielded `[2, 2000]` words despite the 300-word target.
  Flush prior text, split the oversized paragraph, and provide a hard fallback for very long sentences.
  Acceptance: long paragraphs after introductions, sentence-free text, and multilingual fixtures stay
  within explicit limits without losing content or breaking source offsets.
  Evidence: `lib/doctrans/search/chunker.ex:132`. Reproduced. Coordinate with C01 before rebuilding indexes.

## Phase 4 — Viewer, uploads, and local-use experience

- [ ] **U01 · P2 · Render Markdown tables and document typography correctly.**
  MDEx's table extension is not enabled. A valid Markdown table rendered as a pipe-delimited paragraph,
  despite OCR prompts requesting preserved tables.
  Enable tables and verify sanitized table cells, headings, lists, and overflow styles.
  Acceptance: representative OCR tables render as table elements in viewer and chat;
  long tables remain readable; existing sanitization checks pass.
  Evidence: `lib/doctrans_web/live/document_live/markdown_helpers.ex:40`, `assets/css/app.css`.
  Runtime reproduction confirmed the missing table.

- [ ] **U02 · P2 · Preserve the resolved browser locale through LiveView.**
  The HTTP plug detects Accept-Language but deletes the session locale; LiveView then defaults to English.
  Persist the resolved locale, retain explicit choices appropriately, and update the root HTML language.
  Acceptance: browser-language detection and explicit language choices survive mounting, navigation,
  and reload; unsupported locales fall back predictably.
  Evidence: `lib/doctrans_web/plugs/set_locale.ex:39`, `lib/doctrans_web/live/hooks/set_locale.ex:21`,
  `lib/doctrans_web/components/layouts/root.html.heex:2`. German-to-English reset reproduced.

- [ ] **U03 · P2 · Fetch model choices without blocking the viewer.**
  Sending a message to the same LiveView does not make its subsequent model-list HTTP request asynchronous.
  Move it into supervised LiveView async work with cancellation and stale-result handling.
  Acceptance: a slow/unavailable server does not block modal closing, page navigation, progress, or chat;
  late results cannot populate an obsolete modal; errors permit retry.
  Evidence: `lib/doctrans_web/live/document_live/reprocess_modal.ex:37,118`.

- [ ] **U04 · P2 · Report per-file upload outcomes accurately.**
  Mixed validation failures use a warning flash that the layout never renders. Accepted files are counted
  before document creation/enqueue outcomes are known, and enqueue results are discarded.
  Return per-file outcomes, count successful starts, and show entry-specific upload errors.
  Acceptance: mixed success/failure identifies each failed file; failed creation/enqueue never appears
  successful; rejected files have visible explanations and correct cleanup.
  Evidence: `lib/doctrans_web/live/document_live/index.ex:350,365,401`,
  `lib/doctrans_web/components/layouts.ex:58`.

- [ ] **U05 · P2 · Make upload and dialogs keyboard accessible.**
  The file input is display-none and its browse labels are not focusable.
  Provide a keyboard-operable chooser, labeled shared inputs, dialog naming, focus management,
  Escape handling, and accessible names for icon-only controls.
  Acceptance: complete upload and reprocessing using only a keyboard; focus returns to the trigger;
  screen-reader names identify controls. Verify in a real browser.
  Evidence: `lib/doctrans_web/live/document_live/components.ex:155,201`.

- [ ] **U06 · P2 · Keep connectivity notices mounted.**
  AutoDismiss removes all flash nodes after about 5.3 seconds, including initially hidden client/server
  connection-error banners. Later disconnect handlers target missing nodes.
  Limit timed dismissal to transient notifications and update LiveView flash state instead of removing
  LiveView-owned DOM. Keep connectivity notices until connection state resolves.
  Acceptance: disconnecting after a minute still displays a reconnect notice, which clears on reconnect;
  manually dismissed flashes do not reappear from stale server state.
  Evidence: `lib/doctrans_web/components/core_components.ex:36`,
  `lib/doctrans_web/components/layouts.ex:62`, `assets/js/app.js:30`.

- [ ] **U07 · P2 · Make privacy claims match configured inference.**
  Upload text and metadata promise that documents never leave the device even when a remote endpoint is used.
  Match README's conditional wording and identify the processing destination without revealing credentials.
  Acceptance: remote configuration makes the destination clear; local mode accurately describes local
  processing; neither logs nor UI expose API keys. The existing CSP blocks external Markdown images;
  the review did not identify an automatic external-image leak.
  Evidence: `lib/doctrans_web/live/document_live/components.ex:210`,
  `lib/doctrans_web/components/layouts/root.html.heex:9`.

- [ ] **U08 · P3 · Display recorded model provenance.**
  The page-processing-models paragraph is empty and hidden with the progress section at 100% completion.
  Render extraction/translation identifiers and Unknown fallbacks outside the progress-only section.
  Acceptance: processing, completed, and legacy pages display appropriate provenance, including model aliases
  without claiming they identify immutable weights.
  Evidence: `lib/doctrans_web/live/document_live/show.html.heex:82`.

- [ ] **U09 · P3 · Make the viewer responsive and preserve chat reading position.**
  Two horizontal document panels plus a fixed-width chat panel are unsuitable for narrow screens.
  Use mobile tabs/stacking and an overlay chat panel; follow streaming output only when the reader is already
  near the bottom, with a new-message affordance otherwise.
  Acceptance: narrow and desktop layouts remain usable at zoom; streaming does not pull a reader away
  from earlier messages. Verify representative viewports in a browser.
  Evidence: `lib/doctrans_web/live/document_live/show.html.heex:90`,
  `lib/doctrans_web/live/document_live/chat_components.ex:16`, `assets/js/app.js:41`.

- [ ] **U10 · P3 · Move theme initialization into the supported JavaScript bundle.**
  The inline root script conflicts with the router's script-src self policy and project conventions.
  Acceptance: theme selection, reload persistence, and cross-tab updates work without inline scripts
  or weakening the Content Security Policy.
  Evidence: `lib/doctrans_web/components/layouts/root.html.heex:22`, `lib/doctrans_web/router.ex:14`.

- [ ] **U11 · P3 · Refresh the dashboard across tabs.**
  The dashboard subscribes to known document IDs, so another tab's newly uploaded document is missed.
  Subscribe to collection notifications and broadcast creation/deletion consistently.
  Acceptance: upload, deletion, and status changes appear in another open dashboard without a reload;
  subscriptions remain bounded and document streams remain consistent.
  Evidence: `lib/doctrans_web/live/document_live/index.ex:471`, `lib/doctrans/documents/topics.ex`.

## Phase 5 — Verification and maintenance

- [ ] **Q01 · P2 · Correct the warnings-as-errors compiler flag.**
  Both precommit paths use `--warning-as-errors`; installed Mix recognizes `--warnings-as-errors`.
  Correct both invocations and decide explicitly whether test-load warnings must also fail validation.
  Acceptance: a project compilation warning fails each quality entry point; the normal project passes.
  Evidence: `mix.exs:132`, `.pre-commit-config.yaml:116`.
  Verified against local `mix help compile` and compiler option parsing. Do this before the main fix batches.

- [ ] **Q02 · P2 · Include critical workers in meaningful coverage.**
  The reported percentage excludes Worker, LlmProcessor, EmbeddingWorker, and health/sweeper workers.
  Gradually remove production exclusions while adding behavior-focused tests; keep the 80% requirement.
  Remove obsolete Ollama exclusions, clarify the active coverage configuration, and correct the ignore rule
  that labels tracked coveralls.json as an artifact.
  Acceptance: critical processing/indexing behavior contributes to the coverage gate;
  CI and local checks use the same configuration without hiding new gaps.
  Evidence: `coveralls.json:5`, `.coveragerc`, `.gitignore:46`.

- [ ] **Q03 · P2 · Assert successful outcomes and control test background work.**
  Some search tests allow either results or no results and conditionally skip link assertions.
  The passing suite logged database-ownership errors from background tasks.
  Use deterministic retrieval fixtures, assert result IDs/pagination/links, and own/drain supervised work
  before sandbox teardown. Add focused integration coverage for the processing-to-retrieval workflow.
  Acceptance: broken successful retrieval fails its test; routine tests leave no unowned database tasks;
  restart and reprocessing boundary regressions are covered without live model dependencies.
  Evidence: `test/doctrans_web/live/search_live_test.exs:107,139,192`, `test/support/`,
  and the baseline precommit run.

## Optional product backlog — design after the defect fixes

- [ ] **B01 · Per-document source language or language detection.**
  Translation reads one application-wide language, defaulting to German. Store a document/run choice
  so mixed-language uploads and later retries remain reproducible. Migrate existing records deliberately.
  Acceptance: two documents with different source languages process concurrently with the correct choices.
  Evidence: `lib/doctrans/processing/llm_processor.ex:235`.

- [ ] **B02 · Export translated work.**
  Add Markdown download first, preserving page boundaries and provenance; consider formatted document exports
  after validating demand and output quality. There is no current user-facing export route.
  Acceptance: exported content matches completed pages and clearly identifies incomplete/failed pages.

- [ ] **B03 · Processing and indexing status with targeted retry/cancellation.**
  Show queued/running/retry/error states, failed-page count, and index readiness separately.
  Offer targeted retries and cancellation without requiring document deletion.
  Dependencies: C03, R01, R02, R03, R06.
  Acceptance: users can diagnose and recover an indexing failure without rerunning successful translation.

- [ ] **B04 · Model/settings readiness checks.**
  Validate model IDs, embedding dimensions, inference availability, and the processing destination before upload.
  Acceptance: unavailable or incompatible models have specific remediation messages; credentials stay hidden.

- [ ] **B05 · Backup/restore and portable runtime deployment.**
  Document and test consistent backups of the database, originals, generated files, and conversations.
  Validate restore into a different storage root; keep development Compose distinct from an optional
  reproducible runtime deployment. Dependency: R05.
  Acceptance: a restored document can be viewed, searched, chatted with, and reprocessed from its retained source.

- [ ] **B06 · Separate development network binding from database configuration.**
  Development binds all interfaces whenever DATABASE_HOST exists. Introduce an explicit bind setting
  and set it deliberately in Compose so moving the database does not implicitly change application exposure.
  Acceptance: setting a remote database host alone leaves the application on loopback;
  Compose remains reachable through its loopback-published port. Do not introduce authentication.
  Evidence: `config/dev.exs:24`, `docker-compose.yml`.

## Completion criteria

Each completed item has focused evidence for its stated acceptance criteria, applicable translations/docs,
and a passing `mix precommit`. Browser-facing changes include actual browser verification where ExUnit
cannot establish keyboard, responsive, CSP, reconnect, or scrolling behavior. Index or storage changes
include a recovery/migration path for existing documents. Optional backlog items require their own scoped
design before implementation; they are not prerequisites for resolving the confirmed defects.
