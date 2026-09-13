# Doctrans improvement plan

Status: implementation in progress; C01–C05 and Q01 completed, plus Phase 6 items G01–G08.
Base: `main` at `6953656`, reviewed on 11 September 2026.
Phase 6 added 12 September 2026 from a quality-gate, toolchain, and supply-chain review.
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
  Evidence: `lib/doctrans/search/indexer.ex` (`create_chunks/2`, `chunks_match_page_content?/2`),
  `lib/doctrans/chat.ex:141`, `lib/mix/tasks/rechunk_documents.ex`. Reproduced with a chunking probe.
  R01 moved this code out of the deleted `EmbeddingWorker`; the chunking decision is unchanged.

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

- [x] **C03 · P1 · Separate successful completion from failed pages and pending retries.**
  `all_pages_completed?/1` counts extraction errors as completed, including failures awaiting Oban retries.
  Another page finishing can overwrite an error document with `completed`.
  Require successful required stages for success; represent partial failure explicitly and preserve errors
  until retry outcomes justify changing the document state.
  Acceptance: a failed OCR page plus a successful page never produces a successful document;
  scheduled retries remain distinguishable from terminal failure; a successful retry reconciles status.
  Implemented: `Pages.completion_state/1` replaces the boolean check and reports `:completed` only when
  every expected page finished translation, `:failed` when every page settled with at least one failure,
  and `:incomplete` otherwise; success and failure are disjoint so settled pages add up to the page count.
  The orchestrator resolves that state under the existing document lock: success completes and clears the
  diagnostic, an unsettled document is left alone, and a settled failure becomes `error` carrying the
  failed page numbers (`{:pages_failed, ...}`) unless `Run.retry_pending?/1` finds an active job for a
  failed page, which reports `:retrying` and preserves the current state. An error recorded by an
  exhausted page job is never overwritten, and a successful retry or page reprocess reconciles the
  document back to `completed`. A page job that crashes on its final attempt settles the document
  too, instead of leaving it `processing` until the next startup recovery pass. The progress panel
  names the pages to reprocess, from `Summary.failed_pages`, and falls back to the whole-document
  message when no page failed.
  Evidence: `lib/doctrans/documents/pages.ex:156`,
  `lib/doctrans/processing/document_orchestrator.ex:50`, `lib/doctrans/processing/llm_processor.ex:220`.
  Reproduced in a database test using a rolled-back transaction.

- [x] **C04 · P1 · Invalidate stale chat context after single-page reprocessing.**
  Whole-document reprocessing clears saved retrieval context; single-page reprocessing does not.
  Saved context lacks page revisions, and merging retains the higher-similarity copy even when it is obsolete.
  A probe merging corrected `Assets are 100` into higher-ranked old `Assets are 10` retained the old value.
  Carry source revisions through retrieval and persistence, remove obsolete context, and prevent in-flight
  answers from being saved as current when a supporting page generation changes.
  Acceptance: correcting a page updates the next answer after reload and in another open tab;
  an in-flight answer based on the old page cannot restore obsolete context.
  Implemented: chunk and page retrieval now select `pages.content_revision`, and the revision is stored
  with every persisted context chunk. `Chat.merge_context/3` ranks revision before similarity and drops
  chunks superseded by a newer revision of the same page, so re-extraction under a different chunk index
  can no longer leave the old text behind a higher score. `Chat.current_context/1` re-checks chunks
  against current page revisions and drops chunks whose page was reprocessed, deleted, or predates
  revision tracking; it runs when a conversation is loaded, before an answer's context is saved, and on
  the prior context the agent is handed. `reprocess_page/2` deletes that page's saved context under the
  document lock that `Conversations.finish/5` also takes, so an in-flight answer either saves before the
  reset or has its obsolete chunks discarded. Open tabs evict the page's accumulated context from the
  socket on the existing `{:page_updated, page}` broadcast, and a turn that finishes after such a reset
  filters its context once more before it reaches the socket, so the socket never keeps chunks the saved
  session already dropped.
  Evidence: `lib/doctrans/processing/document_reprocessing.ex:59`, `lib/doctrans/chat.ex:179`,
  `lib/doctrans/chat/conversations.ex:15,79`. Merge behavior reproduced; persistence gap traced.
  Residual: the revision fence does not cover translation-only changes — resolved in C05.

- [x] **C05 · P3 · Invalidate saved chat context when only a page's translation changes.**
  `content_revision` advances on `original_markdown` or an `extraction_status` leaving `completed`, and
  page embeddings are generated as soon as extraction completes, before translation is written. A chat
  turn in that window saves page-level context whose `translated_markdown` is still `nil` at the current
  revision, so `Chat.current_context/1` reads it as fresh and `Chat.merge_context/3` can keep it over a
  later, fully translated copy of the same revision that happens to score lower.
  Advance a revision when translated text changes, or prefer the newer copy when revisions are equal.
  Acceptance: a question answered between extraction and translation leaves no untranslated saved context
  once translation completes.
  Implemented: freshness is now decided on page text, not the revision alone. `Chat.current_context/1`
  reads each source page's `translated_markdown` alongside its revision and drops page-level context whose
  stored translation no longer matches the page, so context saved in the extraction-to-translation window
  is discarded once the translation lands — on conversation load, before an answer's context is saved, and
  on the prior context handed to the agent. Chunk-level context is exempt: chunk retrieval returns a nil
  translation, and a translation on legacy saved chunk context is ignored for freshness just as
  `context_content/1` already ignores it for rendering, so chunk freshness stays revision-only. `Chat.merge_context/3`
  ranks a page copy carrying the translation above one retrieved without it at the same revision, ahead of
  similarity, so a higher-scoring untranslated copy can no longer win the dedup; the surviving copy keeps
  the best similarity recorded for its identity at that revision, so preferring the translation never costs
  the page its rank or its place in the byte budget. The same test is exported as `Chat.superseded_by?/2`
  and used by the document LiveView, so a translation completing in another tab evicts the untranslated
  copy from an open socket's accumulated context too; it returns false for a chunk read from another page,
  so callers pass their whole accumulated context without pre-filtering. `content_revision` was not reused
  to carry translation freshness: it fences in-flight embedding and page writes
  (`Indexer.with_current_revision/2`, `Run.with_page/2`), and advancing it on translation would
  discard the embeddings generated for that page. A separate `translation_revision` column would be inert
  with respect to both fences and remains open as a cheaper invariant if the text comparison ever costs
  too much; the content check was chosen because it needs no migration and also catches a translation
  rewritten at one revision.
  Evidence: `lib/doctrans/chat.ex:224,285,356`, `lib/doctrans_web/live/document_live/show.ex:368`.
  Reproduced in a database test: page context saved before translation survives the revision check and is
  dropped by the content check.

## Phase 2 — Recoverable processing and indexing

- [x] **R01 · P2 · Move indexing to durable, bounded jobs.**
  Embedding requests and pending work exist only in a GenServer and supervised tasks.
  Startup recovery does not recover indexing for fully translated pages. Restart, task failure, or exhausted
  retries can leave completed documents unavailable to semantic search/chat until manually reprocessed.
  Use Oban with page-generation-aware uniqueness, bounded concurrency, and pending/error reconciliation.
  Acceptance: restart during indexing eventually restores search/chat; transient failure retries persist;
  duplicate requests do not create duplicate work; obsolete generations cannot overwrite current vectors.
  Implemented: an indexing request is now a row. `Doctrans.Jobs.EmbeddingJob` runs on a new
  `embedding_generation` queue at concurrency 2 — bounded, where the GenServer started one supervised task
  per page with no ceiling — and `Doctrans.Search.Indexer` holds the chunking and embedding that used to
  live in `EmbeddingWorker`, which is gone along with its coalescing state and its supervision-tree entry.
  The page generation the job is keyed on is `content_revision`, the column the database trigger already
  advances whenever a page's source text changes; `processing_generation` fences a *processing* run and
  says nothing about whether the text changed, so it is the wrong fence for vectors. Uniqueness over
  `[page_id, revision]` across all active states makes a repeated request for a revision already queued
  or running a no-op, while a re-extraction queues a genuinely distinct unit of work. The superseded job
  cannot win if the two overlap: every write the indexer makes still passes `with_current_revision/2`,
  and a run whose fence fails now reports `{:cancel, :stale_page}` rather than the `:ok` it used to
  report after writing nothing. The final "completed" write was fenced before this change too, so the
  row state was never wrong; what changed is that the run no longer reports success for work it skipped.
  Retries moved out of the process and into the schedule: the in-task `Process.sleep` loop over
  `@max_retries` is gone and a transient chunk failure is returned as `{:error, reason}` for Oban to
  retry across restarts. A page is cancelled only when *every* failure on it fails
  `ErrorClassifier.retryable?/1`; classifying the page on whichever chunk happened to fail first would
  let one oversized chunk strand the chunks that failed transiently beside it. A retry only re-embeds
  chunks that still have no vector. The OpenAI client underneath still replays transient failures within
  a single call, which is why the indexer passes `melt: false` rather than melting a fuse the client
  already melts — see R06.
  Startup recovery gained a third phase, `{:embeddings, cursor}`, running after documents and pages with
  the same batch size and cursor. It queues every page whose extraction completed and whose
  `embedding_status` is not `completed` — pending, errored, or left `processing` by a restart — and it
  reads the revision under a row lock so a page rewritten since selection is queued at the revision it
  now holds. Unlike the page phase it does not filter on document status, which is what left fully
  translated pages of completed documents unrecovered.
  That phase matches existing jobs on the page **and** the revision, unlike the page-keyed filter the
  other phases use. A page-keyed filter is wrong for a revision-keyed worker: a job holding a superseded
  revision cancels without indexing anything, so treating it as the page's owner skipped the revision
  that replaced it and left the page unindexed until some later restart. Jobs that already settled the
  current revision by being `cancelled` do suppress recovery, so a permanent failure is not re-queued and
  re-charged to the API on every boot; `discarded` does not, because exhausted retries were retryable
  failures and a restart is a fair new attempt. Retaining that evidence is why `Oban.Plugins.Pruner` now
  keeps history for a week instead of its 60-second default, and each page is queued in its own
  transaction so one unqueueable row costs that page rather than the batch.
  `doctrans.embedding.crashed.count` was dropped from telemetry: the GenServer `:DOWN` handler that
  emitted it no longer exists. Nothing in the app subscribed to Oban's events, so two replacements were
  added rather than assumed. `EmbeddingJob.perform/1` emits `[:doctrans, :retry, :attempt]` and
  `[:doctrans, :retry, :exhausted]` tagged `type: :embedding` — the series `DoctransWeb.Telemetry`
  already declares alongside `:extraction` and `:translation`, and which would otherwise have gone
  silently dead — and `job_metrics/0` adds `[:oban, :job, :stop]` and `[:oban, :job, :exception]` counters
  by queue, which is how a crashed or cancelled job in any queue now surfaces. `Oban.Lifeline` drops from
  a one-hour rescue window to fifteen minutes: an orphaned `executing` job blocks both recovery and
  re-enqueue for the page it holds, and an hour is far longer than any real indexing run.
  Evidence: `lib/doctrans/jobs/embedding_job.ex`, `lib/doctrans/search/indexer.ex`,
  `lib/doctrans/processing/startup_recovery.ex:99`, `config/config.exs:121`. Reproduced in database tests:
  a job carrying a superseded revision cancels and leaves the current vectors untouched, a transient
  failure is reported for retry and succeeds on the next attempt, recovery queues indexing for a
  completed document the page phase never looks at, and recovery still queues the current revision while
  a superseded job for the same page is active — which fails against a page-keyed filter.

- [x] **R02 · P2 · Track failed page embeddings accurately.**
  Successful chunk embeddings are followed by a page embedding call whose failure is only logged;
  the page is then marked indexed. Global search relies on page embeddings and silently loses semantic coverage.
  Track/retry page indexing separately, or standardize global search on chunk retrieval.
  Acceptance: chunk success plus page embedding failure cannot report complete global indexing;
  retry restores semantic search without rerunning OCR/translation.
  Implemented: the page-level call's result is no longer discarded. A page whose chunks embedded but
  whose page vector did not is reported as `{:error, reason}` or `{:cancel, reason}` like any other
  failure and left at `embedding_status: "error"`, so Oban retries it and startup recovery — which keys
  on that status — can still see it. Marking it `completed` was the trap: global search requires
  `p.embedding IS NOT NULL`, so the page was absent from search with nothing left to notice it, and
  R01's new recovery query would have made that permanent rather than merely long-lived. The chunk
  vectors are kept, so the retry owes only the page-level call.
  Evidence: `lib/doctrans/search/indexer.ex` (`finish_page_level_embedding/3`), `lib/doctrans/search.ex:336`.
  Reproduced in a database test that fails only the call carrying the whole page's text.

- [x] **R03 · P2 · Reconcile document completion on replay and restart.**
  The last translation is saved before document completion is updated. A crash between those writes leaves
  a processing document whose resumed job skips completed stages and whose pages startup recovery excludes.
  Recheck completion on every successful replay and reconcile eligible documents during startup.
  Acceptance: a processing document with all final pages saved reaches the correct terminal state after
  job replay or startup, without making another model request. Cover failed pages using C03's status semantics.
  Implemented: the completion check moved out of the two branches that happened to write the last
  translation and into `do_process_page/2`, so it runs once on every successful page job — including the
  replay that skips both stages because they are already saved. That replay used to return `:ok` without
  ever looking at the document again, which is what made the crash window permanent rather than
  self-healing; resolving it costs no extra query and no model call, because the check reuses the page
  the run already read and so keeps the orchestrator's revision fence meaningful.
  Startup recovery gained a fourth phase, `{:completion, cursor}`, batched and cursored like the others.
  It selects `processing` documents with a known page count and no unsettled page, and hands each to
  `DocumentOrchestrator.check_document_completion/1`, so C03's rules — success only when every expected
  page succeeded, `{:pages_failed, ...}` when they all settled with a failure, and no change while a
  failed page's retry is still pending — decide the outcome. The phase queues nothing. Per-row database
  failures are contained and logged, as in the embedding phase, so one bad row cannot abandon the cursor
  mid-batch or restart the whole pass.
  It runs last on purpose. The page phase resets a failed page to `pending` and queues a retry, which
  unsettles the document again; settling failures before that ran would record an error for a page that
  recovery is about to reprocess. Documents already in `error` are deliberately left out: only a
  `processing` document is mid-run, and reconciling an `error` document would resurrect one an operator
  or a document-level failure deliberately stopped.
  "Settled" is now a query-land predicate, `Page.settled?/1`, which delegates to the existing `failed?/1`
  rather than restating it, so the recovery filter and `Pages.completion_state/1` cannot drift apart.
  Evidence: `lib/doctrans/processing/llm_processor.ex` (`do_process_page/2`),
  `lib/doctrans/processing/startup_recovery.ex` (`run_batch({:completion, _})`),
  `lib/doctrans/documents/page.ex` (`settled?/1`). Reproduced in database tests: a replay of a fully
  saved page completes its document against an OpenAI stub that raises on any call, the same replay
  settles a document whose other page failed, one replay drives the Oban job itself rather than the
  processor, and the startup phase completes, settles, or leaves each document alone according to C03's
  states — including leaving an already-failed document untouched.
  Dependency: C03.

- [x] **R04 · P2 · Bound PDF subprocess execution and resources.**
  `pdfinfo` and `pdftoppm` run through unbounded `System.cmd`; the extraction job has no deadline,
  and extraction concurrency is one. A hung renderer can occupy the only slot indefinitely.
  Reuse the monitored LibreOffice subprocess approach with deadlines, bounded diagnostics, child cleanup,
  and configurable page/image resource limits.
  Acceptance: a fake hung renderer times out and is reaped; subsequent extraction can run;
  excessive diagnostic output is bounded; legitimate larger documents have actionable limit errors.
  Implemented: the converter's port machinery moved into `Processing.Subprocess` — a deadline that output
  cannot reset, a 64 KiB tail of diagnostics, a SIGKILL of the child's process group on every exit path,
  and a monitored owner that reaps the child when the caller dies mid-run. Extracting it rather than
  copying it is the point: the renderer and the converter now fail the same way, and a fix to one is a
  fix to both. `DocumentConverter` kept only what is LibreOffice's — profile creation, argument
  assembly, and its own error vocabulary — and its existing tests, including the launcher-child and
  caller-kill cases, pass against the shared module unchanged.
  Both poppler commands now run through it with separate deadlines, because the two calls are not
  comparable: `pdfinfo` reads a header (15 s) while `pdftoppm` rasterizes a page (120 s). Executables
  resolve like `soffice` does — a configured path when it is executable, otherwise `$PATH` — which is
  what let the hang, the flood, and the limits be tested against fake renderers instead of a real one.
  Credentials are removed from every child environment, replacing the `env: [{"PATH", ...}]` that ports
  cannot express.
  Two limits bound one document's demand, both under `:pdf_extraction`. `:max_pages` is checked in
  `get_page_count/1`, the single call that decides how much extraction follows, so an oversized document
  is rejected before a page is rendered rather than after several hundred are. `:max_image_bytes`
  rejects a rendered page and deletes it — leaving the file would make a lower `:dpi` take no effect,
  because extraction treats a stored image as a finished page. Both errors report the value and the
  limit, so the answer is a smaller document or a lower resolution.
  The job's own deadline is `DocumentExtractionJob.timeout/1`, since a document is many bounded runs and
  the product of the two bounds is not a useful ceiling. A timeout there costs nothing: rendered pages
  stay on disk and in the database, and `ensure_page/4` makes the retry resume rather than restart.
  Evidence: `lib/doctrans/processing/subprocess.ex`, `lib/doctrans/processing/pdf_extractor.ex`,
  `lib/doctrans/jobs/document_extraction_job.ex` (`timeout/1`), `config/config.exs` (`:pdf_extraction`).
  Reproduced against fake poppler executables: a hung renderer times out, its process group is reaped,
  and the next extraction in the same slot succeeds; a renderer printing continuously still dies at its
  deadline; 280 KB of error output arrives as 64 KiB; and the page and image limits report their numbers.

- [ ] **R05 · P2 · Use one runtime storage root for writing and serving images.**
  Writers use `Config.Uploads.upload_dir/0`, but the endpoint always serves `priv/static/uploads`.
  Custom storage can successfully process documents while returning broken page-image URLs.
  The default root is also expanded during build configuration, which complicates portable releases.
  Resolve the runtime data directory consistently and retain the generated-image-only serving restrictions.
  Acceptance: upload, view, reprocess, restart, and delete work with a nondefault data root;
  originals and converted PDFs remain inaccessible through HTTP; image responses retain no-store headers.
  Evidence: `lib/doctrans_web/endpoint.ex:46`, `config/config.exs:47`.

- [x] **R06 · P2 · Give retries and circuit breakers clear ownership.**
  Indexing melted the breaker around a client that already classifies and melts failures.
  Transient errors can count twice, and permanent errors can count through the outer wrapper.
  Remove duplicate accounting and reconcile Req, processor, and Oban retry policies into documented bounds.
  Acceptance: one transient operation failure counts once; permanent API errors do not open the circuit;
  permanent failures do not receive ordinary transient job retries; cancellation does not wait through
  unnecessary nested sleeps. Preserve existing error-code conventions.
  Implemented: both embedding calls in `Search.Indexer` now pass `melt: false`, matching the chat paths.
  `OpenAI.embed/2` classifies its own failures and melts `:embedding_api` only for retryable ones, so the
  outer wrapper was counting transient failures twice and melting on the 401s and 400s the client
  deliberately ignores — blowing the fuse at roughly half its configured tolerance, on errors that a
  fuse cannot help with. Retry ownership itself was settled by R01: Oban holds the schedule, the indexer
  holds no loop, and Req still replays transient failures within one call.
  Evidence: `lib/doctrans/search/indexer.ex` (`embed/1`), `lib/doctrans/processing/openai.ex:455-465`.

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

- [x] **Q01 · P2 · Correct the warnings-as-errors compiler flag.**
  Both precommit paths use `--warning-as-errors`; installed Mix recognizes `--warnings-as-errors`.
  Correct both invocations and decide explicitly whether test-load warnings must also fail validation.
  Acceptance: a project compilation warning fails each quality entry point; the normal project passes.
  Evidence: `mix.exs:132`, `.pre-commit-config.yaml:116`.
  Verified against local `mix help compile` and compiler option parsing. Do this before the main fix batches.
  Implemented: both call sites corrected. The unknown switch was measured, not assumed — in a scratch
  project carrying a deliberate unused-variable warning, `--warning-as-errors` exits 0 and
  `--warnings-as-errors` exits 1, and the singular form behaves identically to a nonsense switch such as
  `--banana`. Mix neither rejects nor warns about it, so this gate had never failed a build since it was
  introduced. Fixing it unmasked no backlog: `mix compile --force --warnings-as-errors` is clean in both
  `dev` and `test` (86 and 100 files). The test-load question is deliberately left open as Q07, because
  `mix compile` never sees `test/**/*.exs` and exactly one warning hides in that blind spot.

- [ ] **Q02 · P2 · Include critical workers in meaningful coverage.**
  The reported percentage excludes Worker, LlmProcessor, and the health/sweeper workers.
  Gradually remove production exclusions while adding behavior-focused tests; keep the 80% requirement.
  Remove obsolete Ollama exclusions, clarify the active coverage configuration, and correct the ignore rule
  that labels tracked coveralls.json as an artifact.
  Acceptance: critical processing/indexing behavior contributes to the coverage gate;
  CI and local checks use the same configuration without hiding new gaps.
  Evidence: `coveralls.json:5`, `.coveragerc`, `.gitignore:46`.
  Measured 12 September 2026 by overriding the ExCoveralls config path at the BEAM level
  (`ELIXIR_ERL_OPTIONS='-excoveralls config_file ...'`) and re-running with `skip_files` emptied,
  so no tracked file was touched. Honest coverage of all of `lib/` is **86.2%** (2871 relevant lines,
  397 missed); the measured subset reports 89.6%; the excluded files sit at **66.2%**. Because 86.2%
  clears the existing 80% gate, the seven production exclusions can be deleted outright with no
  threshold change and no new tests — do that first, then close the gaps below.
  Per-file reality: `health_check_worker.ex` 37.2%, `embedding_worker.ex` 59.1%, `llm_processor.ex` 67.5%,
  `sweeper_worker.ex` 70.0%, `health_check.ex` 78.2%, `worker.ex` 95.9%. Two entries
  (`processing/ollama.ex`, `test/support/ollama_stub.ex`) named files that no longer exist and were
  removed in G07. Superseded in part by R01: `embedding_worker.ex` was deleted and its exclusion with it,
  so its successors `search/indexer.ex` and `jobs/embedding_job.ex` are measured. Five production
  exclusions remain; the measurement above predates that change.
  What the exclusion hides is exactly the reliability logic this plan prioritizes, all of it unexecuted:
  both retry-with-backoff and permanent-failure arms in `llm_processor.ex:183-215,292-324`; the whole of
  `handle_chunk_error/5` and the `Ecto.StaleEntryError` rescue, and `chunks_match_page_content?/2` (the
  C01 alignment decision) — all three formerly in `embedding_worker.ex` and now measured in
  `search/indexer.ex`;
  and the entire check cycle in `health_check_worker.ex:98-180`, which never runs because
  `config/test.exs:60` disables the worker. The retry paths are cheap to cover — `config/test.exs:52-55`
  already sets `max_attempts: 2, base_delay_ms: 10`, so a retry test costs about 20 ms.
  `.coveragerc` is dead configuration: it is a `coverage.py` filename holding Elixir list syntax, nothing
  reads it, and `grep -r coveragerc` matches only this plan. Delete it rather than reconciling it — a
  second exclusion list that cannot take effect makes the real one look reviewed.

- [ ] **Q03 · P2 · Assert successful outcomes and control test background work.**
  Some search tests allow either results or no results and conditionally skip link assertions.
  The passing suite logged database-ownership errors from background tasks.
  Use deterministic retrieval fixtures, assert result IDs/pagination/links, and own/drain supervised work
  before sandbox teardown. Add focused integration coverage for the processing-to-retrieval workflow.
  Acceptance: broken successful retrieval fails its test; routine tests leave no unowned database tasks;
  restart and reprocessing boundary regressions are covered without live model dependencies.
  Evidence: `test/doctrans_web/live/search_live_test.exs:107,139,192`, `test/support/`,
  and the baseline precommit run.
  Diagnosed 12 September 2026. A passing run logs **17 `DBConnection.OwnershipError`s** from two sources.
  First, `Doctrans.Processing.Worker` reschedules startup recovery with
  `Process.send_after(self(), {:recover_batch, next}, 1_000)` (`lib/doctrans/processing/worker.ex:209-216`);
  a test that enables `background_processes` lets recovery begin, the test ends, and the message lands
  1 s later with no sandbox owner, so the GenServer crashes and the supervisor restarts it mid-suite.
  `test/doctrans/processing/worker_test.exs:9-30` already compensates with a `Process.sleep(50)` and an
  `ensure_worker_responsive/1` helper that retries on `:exit` — the suite is working around a bug it causes.
  The second source named in this diagnosis — `EmbeddingWorker` tasks spawned under
  `Doctrans.TaskSupervisor` — no longer exists: R01 deleted the module, and indexing now runs inside an
  Oban job. Re-measure before acting; only the `Processing.Worker` source above is known to remain.
  The fix already exists and is dead code: `test/support/worker_helpers.ex:20` calls
  `Ecto.Adapters.SQL.Sandbox.allow/3` correctly, but `grep -rn "WorkerHelpers\|setup_worker_sandbox"`
  matches only its own definition. That single call site is the only `Sandbox.allow/3` in the tree.
  Oban is `testing: :inline` (`config/test.exs:66`), so job bodies are fine; the gap is the four always-on
  GenServers. Fixing this also removes the 0.3% run-to-run coverage jitter that would eventually make a
  threshold gate fail spuriously.
  Related cleanup in the same pass — tests that cannot fail:
  `test/doctrans/search/embedding_worker_test.exs` was 26 lines covering a 361-line module, asserting that
  `GenServer.cast` returns `:ok` and that the compiler compiled — deleted in R01 along with its subject;
  `test/doctrans/resilience/health_check_worker_test.exs` is 7 `Map.has_key?` assertions on a static struct
  plus `interval_ms == 60_000`; `test/doctrans/processing/pdf_extractor_test.exs:65-108` wraps three error
  tests in `rescue ErlangError -> :ok`, so any unexpected crash is rescued into a pass;
  `test/doctrans/processing/openai_test.exs:30-47` asserts `is_boolean(...)` and reaches the live network;
  and `worker_test.exs` has five `is_map(status)` assertions each preceded by a sleep.
  Of 13 `Process.sleep` calls in tests, 11 are races being papered over; the two in
  `document_converter_test.exs:253,419` and two in `openai_request_test.exs:642,644` are legitimate fixture
  behavior. Only 8% of suite wall time is parallel (0.9 s async vs 55.8 s sync), mostly because
  `Application.put_env` on `:openai`/`:uploads`/`:pdf_extractor_module` forces `async: false`.

- [ ] **Q04 · P2 · Fix chunk byte offsets and assert them with a property.**
  `Chunker` writes `start_offset`/`end_offset` to the `chunks` table, and they do not slice back to the
  chunk content. A probe against the real module produced 14/14 mismatched offsets for a long single
  paragraph and 6/6 for ordinary paragraphs; chunk 1 of the first case has content starting
  `"Sentence number 38 has…"` while `binary_part(text, start_offset, len)` yields `"e number 37 has…"`,
  with drift compounding across chunks. Two causes: `split_long_paragraph` advances offsets by
  `byte_size(Enum.join(sentences, " "))`, discarding the original separators, and `finalize_paras` joins
  on a literal `"\n\n"` when the source may have `"\n\n\n"`.
  Word counts are preserved in every case, so no text is lost and retrieval quality is unaffected; nothing
  currently reads the offsets back. This is therefore a latent data defect, not a user-visible one — but it
  is a P1 test-quality defect, because the three tests named "byte offsets are consistent",
  "byte offsets are correct for multi-byte characters", and "preserves start and end offsets" assert only
  `start_offset >= 0` and `end_offset > start_offset`, on single-chunk inputs. They are the clearest
  instance in the repo of a test that cannot fail.
  Fix the offset arithmetic, then replace those three tests with the property
  `binary_part(trimmed, c.start_offset, c.end_offset - c.start_offset) == c.content` for every chunk.
  Acceptance: the property holds for generated paragraph shapes including multi-byte content, repeated
  blank lines, and paragraphs long enough to split; a deliberate reintroduction of either bug fails it.
  Evidence: `lib/doctrans/search/chunker.ex:171-176,183-211`, `lib/doctrans/documents/chunk.ex:17-18`,
  `test/doctrans/search/chunker_test.exs:74,84,95`. Reproduced with a probe against the real module.

- [ ] **Q05 · P2 · Add property tests for the invariants that fixtures state only by example.**
  Add `{:stream_data, "~> 1.4", only: [:dev, :test]}` and four properties, in value order.
  `Chunker.chunk/1`: the offset round-trip above, plus word-multiset preservation, contiguous
  `chunk_index` over `0..n-1`, and non-decreasing `start_offset` — this restates C01's "retain every
  passage" acceptance criterion as an invariant instead of two fixtures, and guards the three-way `cond`
  in `accumulate_paragraph/2` (`chunker.ex:131-145`).
  `Validation.sanitize_filename_string/1`: for any binary, `Path.basename(r) == r`, no `/`, `\` or NUL,
  no `..`, and `Path.expand(Path.join(dir, r))` stays under `dir`. Five example tests cover this today and
  none states the last clause, which is the one that matters.
  `Chunker.content_for_embedding/2`: the result always ends with the chunk's own content and any prepended
  prefix is a suffix of the previous chunk — this is the embedded-versus-stored divergence surface from C01,
  and `tail_words/2` (`chunker.ex:166-169`) re-joins on `" "`, the same bug class as Q04.
  Explicitly not worth it: revision monotonicity (the failure mode is concurrency, already modelled by
  `document_reprocessing_race_test.exs` and `indexer_race_test.exs`, and a property would assert
  `n + 1 > n`), changeset validation, and LiveView rendering — all small enumerable spaces better served by
  table-driven examples.
  Acceptance: each property fails when its invariant is deliberately broken; run counts and collection
  sizes are bounded so pull-request latency stays predictable; minimal counterexamples are kept as
  regression examples.

- [ ] **Q06 · P2 · Cover the remaining trust boundaries and bound the inference client.**
  Upload and image serving are the best-tested boundaries in the app and need only two additions: a
  zero-byte file at the LiveView level (`validation_test.exs:215` covers the unit), and a corrupt PDF with
  valid magic bytes but a garbage body, which passes `validate_file_content/2` and then fails at `pdfinfo`.
  `endpoint_test.exs:41-116` already covers traversal, encoded traversal, and original-file access across
  GET/HEAD, and `plugs/upload_images.ex` is at 100% — no action there.
  Two real gaps remain on the inference client. A slow or drip-feeding endpoint is never caught: the
  300 s `receive_timeout` is per receive, not a total deadline, `chat_stream` uses `into:` with the same
  per-chunk semantics, and with `retry: :transient` a hung endpoint can hold a page for roughly 20 minutes.
  There is also no response size bound — `grep max_response_size lib/` returns nothing, so a body is read
  fully into memory. Add a total deadline and a size cap, each with a Bypass test.
  SSRF needs no test: `base_url` resolves only from `Config.fetch!(:openai, :base_url)` and no request path
  can set it. Command injection is not possible in the PDF path either, since the extractor passes an
  argument list — the gap there was the missing timeout, closed by R04.
  Model output reaching `raw/1` is correct by construction and well tested at the unit level
  (`markdown_helpers_test.exs:7-31` uses LazyHTML and covers `<script>`, nested `<iframe srcdoc>`,
  `onerror`, `onclick`, and `javascript:` hrefs). Add one end-to-end test driving a document whose
  `translated_markdown` carries a payload through `DocumentLive.Show`, plus markdown-native vectors
  (`[x](javascript:alert(1))`, `![](data:text/html;base64,…)`, reference-style links).
  Acceptance: a hanging endpoint fails a page with an actionable error inside a bounded time; an oversized
  response is rejected before it is buffered; the sanitizer wiring is proven end to end, not only in unit
  isolation.
  Evidence: `lib/doctrans/processing/openai.ex:126,183-188`, `config/openai.ex:23`,
  `lib/doctrans_web/live/document_live/viewer_components.ex:101-103`,
  `lib/doctrans_web/live/document_live/chat_components.ex:170-172`.

- [ ] **Q07 · P3 · Close the test-file warning blind spot, then reconsider mutation testing.**
  `mix compile` never loads `test/**/*.exs`, so Q01's corrected flag does not reach it. One warning lives
  there today: `test/support/openai_stub_test.exs:23` asserts `is_list(models) and models != []`, which
  the type checker proves always succeeds — a dead assertion that is also proof the blind spot is real.
  Fix the assertion, then add `--warnings-as-errors` to the `test` alias so the gap closes permanently.
  On mutation testing: do not pilot `muex` yet. Mutation testing grades assertions on code the suite
  already executes, and the highest-value logic here has zero executions until Q02 lands, so every mutant
  planted there would survive trivially. The runtime is also unfavourable (846 tests, 57 s, 98% of it
  serial), and the suite is not yet deterministic enough to distinguish a surviving mutant from a flaky
  kill while Q03's 17 ownership crashes and 11 timing sleeps remain. Revisit after Q02 and Q03, scoped to
  `lib/doctrans/search/` and `lib/doctrans/resilience/`, where a full pass is minutes rather than hours.
  Note that `muex` is real and current (0.10.0, released 12 September 2026) — the reason to wait is
  sequencing, not tool maturity.

## Phase 6 — Quality gates, toolchain, and supply chain

Reviewed 12 September 2026 against a September 2026 Elixir/Phoenix CI reference report. Every claim below
was verified against this repository rather than adopted from the report; where the report was wrong for
this project, that is recorded with the item.

The governing finding: **six gates reported success while verifying nothing.** A gate that cannot fail is
worse than an absent one, because it is counted as evidence. Items G01–G19 are all resolved.

- [x] **G01 · P1 · Make the dependency advisory gate real.**
  The `hex-audit` pre-commit hook had `entry: "true"` — the Unix `true` command, displayed as a passing
  check named "Hex security audit". Its comment claimed CI ran `mix hex.audit`; CI never did. Its stated
  justification, that `hex.audit` "cannot ignore specific packages", was obsolete: Hex 2.5.1 added
  `ignore_advisories`/`ignore_retirements` in the `:hex` project section.
  Meanwhile `mix deps.audit` reported "No vulnerabilities found" and exited 0 while `mix hex.audit` exited
  1 with **five advisories**, including **`mint 1.9.3` EEF-CVE-2026-82728 (HIGH)**, an unbounded
  HTTP/1 status-line and chunk-extension buffering DoS. `mint` is a runtime dependency via `req` → `finch`.
  The divergence is not the known mix_audit sync bug (issue 61, real and open, but the local advisory clone
  was healthy at `5246bcc`, 4 September 2026). Two different causes: the mint advisories are EEF/OSV-only
  and absent from the GitHub Advisory Database that mix_audit reads, and mirego's cowlib entry encodes
  `>= 2.9.0, <= 2.16.1` while its own description says the flaw affects 2.9.0 onward, so the locked 2.19.0
  falls outside the range.
  Implemented: the hook now runs `mix hex.audit`; `mint` updated to 1.10.0, which clears both mint
  advisories; the three remaining `cowlib` advisories are acknowledged in `mix.exs` with a dated
  `REVIEW BY 2026-12-12` comment, because cowlib reaches the project only through `:bypass` (test-only) —
  production serves with Bandit, not Cowboy — and upstream has published no fixed version. Hex warns when
  an acknowledgement stops matching the lockfile, so the register cleans itself.
  `mix deps.audit` is deliberately retained alongside it: the two tools read different advisory sources and
  neither is a superset, so the supplementary signal is worth its cost now that it is no longer the only one.
  Acceptance: a new advisory in the lockfile fails the gate; acknowledged entries are listed, dated, and
  warn when they go stale. Verified: `mix hex.audit` exits 0 with all three cowlib findings under
  "Ignored advisories".

- [x] **G02 · P1 · Restore Dialyzer to a working gate.**
  `.dialyzer_ignore.exs` suppressed **49 of 49 findings**. `mix dialyzer` was a 3-second no-op that always
  printed "passed successfully", and `--list-unused-filters` reported zero unused filters only because
  every filter was broad enough that nothing could go stale. Three of the suppressed findings were real:
  `markdown_helpers.ex:36` passed an `MDEx` exception struct to `HtmlSanitizeEx.basic_html/1`, which takes a
  binary — so **any MDEx failure while rendering a document page or chat message raised** instead of
  degrading. The ignore comment blamed the sanitizer's return type; the defect was the argument.
  `index.ex:326` called `File.stat(path, size: true)`; `size` is not a `stat_option` and was silently
  discarded, which marked `validate_disk_size/2` and its caller `no_return` and was why three separate
  warning classes had to be muted for that one file.
  `document_orchestrator.ex` had six specs referencing `Doctrans.Documents.t()`, a type that does not
  exist — `Doctrans.Documents` is a context module with no `@type t`, and the schema is
  `Doctrans.Documents.Document` in `documents/document.ex:19` (named `documents/book.ex` until G16).
  Dialyzer resolved it to `any()` and checked nothing, while an `:unknown_type` filter hid that fact.
  Implemented: the error branch now logs and returns `""`; the bogus option is removed; the six specs point
  at `Documents.Document.t()` and `Documents.Page` gained `@type t`. The five suppressions covering those
  three bugs are deleted, and fixing the specs made a sixth filter provably dead, which
  `--list-unused-filters` then reported and which is also deleted. Findings fell 49 → 31, all remaining ones
  genuinely third-party or flag-induced. The gate now runs
  `mix dialyzer --format dialyxir --list-unused-filters`, so a stale suppression fails the build instead of
  lingering.

- [x] **G03 · P1 · Fix the Dependabot ecosystem identifier.**
  `.github/dependabot.yml` used `package-ecosystem: "hex"`. The valid identifier for Elixir is **`mix`**;
  `hex` exists only as the `hex-organization`/`hex-repository` private-registry types. The config has been
  silently inert since it was added on 6 December 2025 — `gh pr list --author app/dependabot --state all`
  returns zero PRs across the repository's entire history, which is also why nothing surfaced the mint
  advisory. Dependabot *security* updates are alert-driven and do still function, so this was a gap in
  version updates specifically; note that GitHub's alert feed did not flag the mint HIGH either, so alerts
  are not a substitute for the lockfile audit.
  Implemented: ecosystem corrected to `mix`, minor and patch updates grouped into one weekly PR to keep
  review volume sane for a single maintainer, and a `github-actions` ecosystem added, which G13 depends on.
  An npm ecosystem was considered and rejected: there is no `package.json` or JS lockfile anywhere in the
  repo — `assets/vendor/*.js` is vendored and `esbuild`/`tailwind` are standalone binaries — so it would be
  a no-op.

- [x] **G04 · P2 · Collapse the quality gate to one definition.**
  The gate was defined in five places — `mix.exs`, `.pre-commit-config.yaml`, `ci.yml`,
  `docs/CONTRIBUTING.md`, and `README.md:270` — and they had already drifted: the Mix alias ran Dialyzer but
  neither `check_translations.exs` nor `check_module_size.exs`; the hook list ran the reverse. A developer
  following `AGENTS.md` and running `mix precommit` therefore ran a strictly different check set from the one
  that fires on their commit and in CI. That the `--warning-as-errors` typo appeared identically in both
  files is direct evidence the lists were copy-pasted rather than derived.
  Implemented: `.pre-commit-config.yaml` is the single definition and `mix precommit` reduces to
  `["cmd pre-commit run --all-files"]`. Dialyzer moved into the hook list, since the alias no longer runs it,
  and the now-redundant duplicate Dialyzer step was removed from CI. CI continues to invoke
  `pre-commit run --all-files`, so local and CI runs execute the same list by construction.

- [x] **G05 · P2 · Close the formatter's silent scope gap.**
  `mix format --check-formatted` passed while two tracked files were unformatted. `.formatter.exs` inputs
  covered neither `scripts/` nor any dotfile, and `Path.wildcard/1` does not match a leading dot without
  `match_dot: true`, so `.credo.exs` and `.dialyzer_ignore.exs` — the two files most likely to be hand-edited
  under pressure — sat outside the formatting gate.
  Implemented: `scripts/` added and the dotfiles listed explicitly rather than globbed, since an explicit
  list cannot silently miss a file. `scripts/check_module_size.exs` and `scripts/check_translations.exs`
  reformatted accordingly.

- [x] **G06 · P2 · Verify the locked dependency set and re-audit on a schedule.**
  CI ran a bare `mix deps.get`, so a pull request editing `mix.exs` without regenerating `mix.lock` resolved
  fresh versions and rewrote the lockfile mid-run — caught only afterwards by the uncommitted-changes step,
  and misreported there as "please run mix precommit". The workflow also had no schedule, which is precisely
  the gap the mint HIGH sat in: an unchanged lockfile gives CI no reason to run, so an advisory disclosed
  after the last commit goes unnoticed indefinitely. CodeQL's weekly default setup does not close this —
  **CodeQL has no Elixir support at all**, so it analyses only the workflow files and vendored JS.
  Implemented: `mix deps.get --check-locked`, plus a Monday 06:00 UTC `schedule` and `workflow_dispatch`.

- [x] **G07 · P3 · Remove stale and misleading tool configuration.**
  `mix.exs` allowed `{:sobelow, "~> 0.14"}` while the lockfile resolved 0.15.0. Since several 0.15.0 fixes
  are specifically cases where a scan **exited 0 having scanned nothing** (a corrupt version-check cache, and
  a `--save-config`-written `version` key), permitting resolution back to 0.14.x risked silently
  reintroducing a false-green security scan. Pinned to `~> 0.15`. Confirmed `.sobelow-conf` carries no stray
  `version` key. Also dropped two `coveralls.json` exclusions naming files that no longer exist
  (`processing/ollama.ex`, `test/support/ollama_stub.ex`).

- [x] **G08 · P1 · Correct the compiler flag.** See Q01.

- [x] **G09 · P1 · Require status checks before merge.**
  Ruleset 10866831 on `main` enforced deletion, non-fast-forward, linear history, signatures, and a pull
  request — but contained **no `required_status_checks` rule**, and `branches/main/protection` returned
  404. A pull request with a red CI run was mergeable, which made every other item in this phase advisory
  until this landed. This is the highest-value change in the phase and the only one requiring repository
  settings rather than a code change.
  Its prerequisite was the check name: `Run Pre-commit Checks (1.20.3, 29.0.5)`, because the single-entry
  `strategy.matrix` interpolated versions into the job name. Requiring that name would mean the gate
  silently stops matching — and therefore stops applying — the day the toolchain is bumped.
  Implemented: both halves of the prerequisite, because either alone leaves a way to detach the
  requirement. The single-entry matrix is gone, its two versions moved to job-level `env` (`ELIXIR_VERSION`,
  `OTP_VERSION`), which the cache keys and `setup-beam` read — so a toolchain bump no longer touches the
  job name, and G10 has one fewer copy to reconcile. A `gate` job named **`Quality Gate`** was added; it
  `needs: [verify, docker]` and is the only required check, so adding or renaming a job changes nothing in
  repository settings. It carries `if: always()` — without it the job would be *skipped* when a dependency
  fails, and a skipped required check is treated as pending, not failed, which would block merges forever
  instead of reporting the failure. The step reads `toJSON(needs)` and fails unless every dependency
  reports `success`, so `failure`, `cancelled`, and `skipped` all fail the gate.
  The `required_status_checks` rule was then added to ruleset 10866831 with `Quality Gate` bound to the
  GitHub Actions app (integration 15368), so a status of that name cannot be forged by another source.
  `strict_required_status_checks_policy` is left `false`: the ruleset already requires linear history and
  squash merges, and forcing every branch to re-sync before merge costs a full CI run per intervening
  commit for no additional signal on a single-maintainer repository.
  Acceptance: a pull request whose CI fails cannot be merged, and a toolchain bump does not detach the
  requirement. Verified: `gh api repos/sapientpants/doctrans/rulesets/10866831` lists the rule, and the
  pull request implementing this item reports `Quality Gate` as a required check.

- [x] **G10 · P1 · Bump the toolchain and pin it in one place.**
  The pins were Elixir 1.20.3 and OTP 29.0.5. **Elixir 1.20.4 is a security release (CVE-2026-75758,
  recursion in `List.to_string/1` and `to_charlist/1`) and OTP 29.0.6 carries CVE-2026-75538.** Both are now
  adopted. The version was stated in five places: `mise.toml:2-3`, the CI job's `env` block, `Dockerfile.dev:2`,
  `mix.exs:10` (a `~> 1.20` range, intentionally), and `README.md:30` prose.
  Implemented: `mise.toml` is the single source of truth at `elixir = "1.20.4-otp-29"` / `erlang = "29.0.6"`.
  The CI copy is deleted — the `Set up Elixir` step reads `version-file: mise.toml` with
  `version-type: strict`, and the dependency and PLT cache keys, which previously interpolated the `env`
  pins, now interpolate `steps.beam.outputs.otp-version` / `elixir-version`, so the keys still segment by
  toolchain without restating it. The `README.md` copy is deleted too: the prerequisite now points at
  `mise.toml` and `mise install` rather than naming versions. `mix.exs` keeps its `~> 1.20` range, which is
  a compatibility floor rather than a pin and is deliberately not single-sourced.
  That leaves one unavoidable copy. A Docker `FROM` line cannot read a version file, and parameterising it
  with a build `ARG` would only move the literal into the default value while letting
  `docker compose up` drift silently. Instead the copy is made load-bearing: a new
  `check-toolchain-pins` pre-commit hook runs `scripts/check_toolchain_pins.exs`, which treats `mise.toml`
  as authoritative and fails when `Dockerfile.dev`'s tag disagrees. It compares the Elixir version exactly
  and OTP on its major only, since the Docker tag can express no more than `-otp-29`.
  Acceptance: one authoritative version file; CI, Docker, and local tooling agree without hand-copying.
  Verified: both versions exist as `erlef/setup-beam` builds for `ubuntu-24.04` (`OTP-29.0.6`,
  `v1.20.4-otp-29`) and as the `elixir:1.20.4-otp-29` Docker tag; `mise install` resolves to Elixir 1.20.4
  on erts-17.0.6; `mix precommit` passes on the new toolchain; and reverting the `Dockerfile.dev` tag alone
  fails the new hook.

- [x] **G11 · P2 · Tighten the subjective Credo checks to honest thresholds.**
  Four checks were labelled "strict" in `.credo.exs` while being configured **looser than Credo's own
  defaults**: `Refactor.Nesting` 3 (default 2), `CyclomaticComplexity` 10 (default 9), `ABCSize` 50
  (default 30), `ModuleDependencies` 20 (default 10). They passed unconditionally and taught nothing.
  Decision taken 12 September 2026: keep these blocking and move them to Credo's defaults, accepting the
  backlog rather than demoting them to advisory.
  Implemented in four staged commits, one threshold per commit with its refactor. Measured before each
  stage and cleared within it: **9** nesting sites, **1** cyclomatic-complexity site, **17** ABC-size
  sites, **2** module-dependency sites. Every fix is an extraction along an existing seam — the anonymous
  function inside a pipeline becomes a named private one, the branch of a `case` becomes the function it
  was already describing. No behaviour changed and no test was rewritten; the suite stayed at 846 passing.
  The largest change is structural rather than cosmetic: `DocumentLive.Show` reached ten first-party
  dependencies only by moving the chat panel's remaining state transitions into
  `DocumentLive.ChatSession`, which already owned the rest of them. `Show` no longer calls `Doctrans.Chat`,
  `Chat.Agent` or `Chat.Conversations` at all.
  Two corrections to the entry as originally written. `Design.DuplicatedCode` is **not** a case of a
  fitted threshold: Credo's default `mass_threshold` is 40, so the configured 30 was already stricter than
  the default and stays as it is. And `ModuleDependencies` counts every module name appearing in a module
  body, standard library and framework macros included, so at `max_deps: 10` it measures verbosity rather
  than coupling — `DocumentConverter` scored 15 with a single first-party dependency, `Endpoint` 19 with
  three, the other sixteen being the `Plug`/`Phoenix` entries its plug pipeline is made of. The check is
  therefore configured with `dependency_namespaces: ["Doctrans"]`, which is what makes the default
  threshold meaningful here; this narrows what is counted, it does not raise the ceiling. 23 of the 25
  findings at `max_deps: 10` were framework and stdlib noise of exactly this kind.
  `Doctrans.Application` carries a named `excluded_namespaces` exemption: a supervision tree has to name
  its children, and three of its eleven entries (`Doctrans.PubSub`, `Doctrans.TaskSupervisor`,
  `Doctrans.Supervisor`) are registered process names rather than modules. Restructuring the tree to
  satisfy a lint count would be the metric damaging the code.
  Acceptance met: every threshold is at or below Credo's default, none was loosened to make a change pass,
  and `mix credo --strict` is clean at the new values. Verified: adding an eleventh first-party alias to
  `DocumentLive.Show` fails the dependency gate, so it is not passing vacuously.
  G15 is now more pressing, not less: `index.ex` sits at **580/600** lines after this work.

- [x] **G12 · P2 · Make Sobelow findings explicit rather than tolerated.**
  `exit: "high"` means four Low-Confidence `SQL.Query` findings in `lib/doctrans/search.ex:167,196,301,414`
  print on every run and never block. All four were read and are genuine false positives — heredocs with
  `$1..$4` placeholders passed to `Repo.query/2` with no interpolation, flagged only because the query is
  bound to a variable named `sql`. The problem is the disposal method: a fifth low-confidence finding, real
  this time, would join the noise unnoticed.
  Implemented: the four sites carry `# sobelow_skip ["SQL.Query"]` with a per-site justification naming
  which parameters are bound, and `exit: "low"` now makes every confidence level block.
  Acceptance: deleting one of the four annotations fails the gate with exit 1 on a single low-confidence
  finding, so it is not passing vacuously.

  **The plan's second paragraph was wrong and is corrected here.** It claimed the 18 existing
  `# sobelow_skip` annotations suppress nothing, that eight are excluded by `private: false`, and that the
  ten `Traversal.FileModule` ones cover a check that never fires. Measured against this repository on
  Sobelow 0.15.0: toggling `skip` yields **23 findings off, 4 on** — the annotations were already
  load-bearing and suppressed 19 findings, all of them `Traversal.FileModule`, which fires freely.
  `private` is not a private-function switch at all: its only effect (`sobelow.ex:691`) is to suppress the
  version-check phone-home and the write to `~/.sobelow`. Setting `private: true` changes the finding count
  by zero — verified at all four combinations of `private` × `skip`. It is set anyway, on its own merit: a
  quality gate should not reach the network to run.
  The real defect in that register was smaller and different. Removing each of the 19 annotations one at a
  time and re-scanning shows **four suppress nothing**: `documents.ex:246` (`delete_document`),
  `document_processor.ex:72` (`extract_convertible_document`), `pdf_processor.ex:32` (`extract_document`),
  and `run_cleanup_job.ex:31` (`stale_run_dirs`). The first three delegate and contain no `File` call; the
  fourth calls `File.ls`, which is absent from `Traversal.FileModule`'s `@file_funcs`. Those four markers are
  deleted and their justification prose kept as plain comments, per the plan's instruction. All 19 remaining
  annotations are confirmed live, each mapping to at least one finding.

  `Config.CSP` and `Config.HTTPS` stay ignored — correct for a loopback-bound single-user app — with the
  rationale and its invalidating conditions now recorded in `.sobelow-conf`. The app renders LLM-extracted
  content from arbitrary uploads through `raw/1` at exactly two sites, both routed through
  `MarkdownHelpers.sanitize_html/1`; CSP would be the defence-in-depth for a sanitizer bug and there is no
  second layer. `scripts/check_raw_call_sites.exs` pins that invariant as a register of file → call-site
  count, wired into pre-commit. Verified it fails on all three divergence modes: a `raw(` site in an
  unregistered file, a second site in a registered file, and a stale register entry whose site was removed.
  Verified overall: `mix sobelow --config` reports zero findings and exits 0.

- [x] **G13 · P2 · Pin actions by SHA and stop persisting credentials.**
  Every `uses:` in `ci.yml` floats on a mutable major tag, `erlef/setup-beam@v1` most notably. Neither
  checkout sets `persist-credentials: false`, so a `GITHUB_TOKEN` is written into `.git/config` for the whole
  job — and that job downloads and executes hook code from five external repositories. The token is
  `contents: read`, which caps the blast radius, hence P2 rather than P1.
  Implemented: all eleven `uses:` references pinned to a full commit SHA with a `# vX.Y.Z` comment, and
  `persist-credentials: false` on both checkouts. Each is pinned at the current latest major rather than at
  the tip of the major it was floating on: `actions/checkout` v7.0.1, `erlef/setup-beam` v1.24.1,
  `actions/setup-python` v7.0.0, `actions/cache` v6.1.0 (shared by the bare, `/restore`, and `/save` entry
  points, which are one repository), `docker/setup-buildx-action` v4.3.0, `docker/build-push-action` v7.3.0.
  Pinning a stale major would have been the smaller change but the worse resting state: a SHA does not
  expire on its own, so whatever it names is what runs until someone acts, and three of the six were several
  majors behind.
  The upgrade was checked against release notes rather than assumed. The majors crossed are almost entirely
  Node 20 → Node 24 runtime bumps plus an ESM migration, requiring Actions Runner ≥ 2.327.1, which
  `ubuntu-latest` satisfies; there are no self-hosted runners. The removals in those notes are all of inputs
  this workflow does not set — `setup-python`'s `pip-install`, `setup-buildx-action`'s deprecated
  inputs/outputs, `build-push-action`'s `DOCKER_BUILD_NO_SUMMARY` and `DOCKER_BUILD_EXPORT_RETENTION_DAYS`.
  `checkout` v7 blocks fork-PR checkout under `pull_request_target` and `workflow_run`, neither of which
  this workflow triggers on. `persist-credentials` is still an input on v7 and still defaults to `true`,
  and `actions/cache` v6 still ships the `restore` and `save` sub-actions — both verified at the pinned SHA
  rather than taken from the README.
  One correction the upgrade forced: `checkout` v6 moved the persisted token out of `.git/config` and into a
  credentials file under `RUNNER_TEMP` that `.git/config` includes. It is out of the repository but still
  readable by any step in the same job, so the item's premise holds and the mitigation is unchanged — but
  the comment justifying it would have been false as written, which is the failure mode G02 and G18 are
  about. It now describes v7's actual mechanism.
  Freshness from here is G03's `github-actions` Dependabot ecosystem, already landed. The version comment is
  load-bearing for that: Dependabot reads it to know what a SHA-pinned action currently is, and rewrites
  both halves together.
  Neither rule survives on care alone — every action's README documents the floating-tag form, so the
  regression is one paste away — so `scripts/check_action_pins.exs` pins both invariants and runs in
  pre-commit, in the same idiom as `check_toolchain_pins.exs` and `check_raw_call_sites.exs`.
  Acceptance: verified the check fails on each divergence mode — a floating tag, a SHA with no version
  comment, a checkout missing `persist-credentials: false` — in both the `- name:`/`uses:` and bare
  `- uses:` step forms, and that it reports zero with the workflow as committed.

- [x] **G14 · P2 · Give suppressions an owner and an expiry.**
  Every remaining `.dialyzer_ignore.exs` entry is `{file, warning_class}`, the broadest granularity dialyxir
  offers, with no owner, date, upstream link, or expiry. The file header recommends auditing with
  `--list-unused-filters`, but that command cannot detect an over-broad filter — only a completely dead one.
  G02 demonstrated the failure mode concretely: two entries carried confident, plausible, and wrong
  diagnoses of bugs nobody had actually investigated.
  Narrow the keys to `{file, description, line}` so a filter dies when the code moves; require owner, expiry,
  upstream link, and rationale per entry; and enforce expiry with a small script alongside
  `check_module_size.exs`. Cap the register, so adding the next entry is a decision rather than a reflex.
  Also drop `:underspecs` from the Dialyzer flags: it is the sole source of the remaining
  `contract_supertype` findings, so removing one flag removes several file-level mutes. Prefer one explicit
  decision over three suppressions.
  Implemented: `:underspecs` is gone, and with it all five `contract_supertype` findings and both resilience
  file mutes — one flag decision for two suppressions, as predicted. The register is now six
  `{file, warning_class, line}` entries, each preceded by `owner`, `expires`, `upstream`, and `rationale`
  comments, enforced by `scripts/check_dialyzer_filters.exs` in the same idiom as `check_action_pins.exs`.
  The cap is 8: the ninth entry has to raise it on purpose.
  Narrowing the keys surfaced a detail the dialyxir README does not state: the filter's third element is
  compared verbatim against the warning's location term, and a warning that carries a column reports
  `{line, column}`, not `line`. An integer-line filter for those warnings matches nothing and is silently
  useless — confirmed by running both forms side by side, where `{"lib/doctrans/validation.ex",
  :pattern_match_cov, 224}` was reported under "Unused filters" while the `{224, 8}` form matched.
  `upstream` is `none` on all six entries, which is the honest value: five are first-party, and for the
  `Gettext.Plural.plural/3` opaque call — generated code, reported at line 1 of `gettext.ex`, once per
  plural form in `priv/gettext` — no upstream issue was found. Inventing a plausible link would be the
  exact G02 failure mode this item exists to prevent, so the rationale says to recheck after the next
  gettext/expo bump instead.
  Two entries (`fixtures.ex:40`, `worker_helpers.ex:16`) are one `_ =` binding away from deletion. They are
  documented rather than fixed, so that this item changes the gate and not the test-support code; their
  expiry is when that trade gets re-decided. All six expire 2026-12-12, matching G01's acknowledgement
  cadence.
  The hook is `always_run: true`, unlike its siblings: an expiry is a date, not a file change, and a register
  nobody touches is exactly the one that goes stale. `--list-unused-filters` stays alongside it — it
  retires a filter whose code moved, which the register check cannot see, and the register check reads the
  justification, which `--list-unused-filters` cannot.
  Acceptance: verified `MIX_ENV=test mix dialyzer --list-unused-filters` reports 0 warnings and 0 unused
  filters with the register as committed, and that the check fails on each divergence mode — an expired
  entry (`--today 2027-01-01`), a missing `# owner:`, a non-ISO expiry, a `{file, class}` two-tuple, a bare
  string filter, a regex filter, a filter naming a file that no longer exists, and a ninth entry over the cap.

- [x] **G15 · P2 · State the module-size limit once, and decide what it is for.**
  Three limits existed for one rule: `scripts/check_module_size.exs` defaulted to 500, pre-commit passed
  `--max-lines 600`, and the Mix alias did not run it at all before G04.
  **The 600 was never a considered limit.** `git log -S` puts its arrival in `590b8d4` (#17,
  9 December 2025), a feature PR whose own changelog line reads "Increase module size limit from 500 to
  600 lines" between an Ollama timeout bump and a coverage exclusion. The number moved so the feature
  could land — which is precisely the failure mode the limit exists to catch, performed on the limit
  itself.
  Implemented: `--max-lines` is **required with no default**, so a caller cannot disagree with a default it
  cannot see, and the number is stated exactly once, in `.pre-commit-config.yaml`. The plan's alternative —
  "hoist the number into one config read by both callers" — was dropped because G04 left only one caller:
  `mix precommit` delegates to `pre-commit run --all-files`, so a config file would be a second place to
  look for a number with a single reader.
  The off-by-one is fixed: `String.split("\n") |> length()` counted the empty string after the terminating
  newline, so every file measured one line longer than `wc -l` and than an editor shows, and every reported
  overage was wrong by one with it. `index.ex` read 581 for a 580-line file. Only the single terminating
  newline is now discarded, so trailing blank lines still count.
  The `.ex`-only scope is documented on the script and in its `--help`, with the reason (`.exs` files are
  read top to bottom rather than navigated, so length is not the same signal), and an explicitly named
  non-`.ex` file now aborts instead of being dropped silently — `check_module_size.exs mix.exs` used to
  report a pass it had not performed.
  A fourth vacuous-pass mode was found while fixing the third and is also closed: a path matching no `.ex`
  files printed "All modules are within the limit" and exited 0. Renaming `lib/` would have retired the
  gate silently. It now aborts.

  **Decision: it stays blocking, and the threshold returns to 500.** Advisory was rejected on this
  repository's own governing finding. `pre-commit` renders a hook that cannot fail as "Passed", so an
  advisory metric left in the gate list would be counted as evidence — G01's defect exactly, where
  `entry: "true"` displayed as a passing security audit. Moved out of the gate list to escape that, it
  would be run by nobody and rot, which is the same outcome as deletion with extra steps.
  The plan's premise that line count is "uncorrelated with the property of interest" is half right, and the
  half that is wrong decides the item. Credo measures complexity and coupling directly, at its own defaults
  since G11 — and `index.ex` passed `Refactor.Nesting` 2, `CyclomaticComplexity` 9, `ABCSize` 30 and
  `ModuleDependencies` 10 while holding a 127-line template, a five-stage upload pipeline and a
  stream-ordering subsystem in one module. Line count is the only check that sees a module accumulating
  several *simple* responsibilities, because every individual function in such a module is shallow, short
  and cheap. That is now written on the script as the one property it is for.
  So the fix for "the gate fires hardest on the worst file" is to fix the file, not to keep the number that
  was fitted to it. 500 is the value the script documented from the day it was written, and `index.ex` is
  split to meet it, along two seams the code already had, in the `DocumentLive.ChatSession` idiom G11
  established: `DocumentLive.UploadIntake` (the on-disk size re-check, magic-byte validation, move-into-place
  and record creation — no socket, which is worth the separation on its own: those checks are the only thing
  between an arbitrary browser upload and the filesystem) and `DocumentLive.DocumentStream` (the ordered
  `:documents` stream and its per-document subscriptions). `index.ex` goes 580 → 360, and sits at 72% of the
  limit rather than 97%. The extractions are moves: no behaviour changed, no test was rewritten, and the
  suite stayed at 846 passing.
  `openai.ex` is now the largest module at 489, which is 98% of the limit. That is recorded rather than
  pre-emptively refactored — it is one module with one responsibility, and splitting it to buy headroom
  would be the metric damaging the code. If it crosses, it gets split; the limit does not move again
  without an entry here saying so.
  Acceptance: full `mix precommit` green with the limit at 500. Verified the gate is not passing vacuously
  by padding `openai.ex` to 501 lines, which fails with a one-line overage — so the count and the boundary
  are both exact. Verified the script aborts on each divergence mode: a missing `--max-lines`, a
  non-positive `--max-lines`, an unrecognised option, an explicitly named `.exs`, a path that does not
  exist, and a directory holding no `.ex` files.

- [x] **G16 · P2 · Gate compile-time cycles with `mix xref`; do not adopt Boundary.**
  Architectural enforcement was assessed and **Boundary is rejected** on evidence. The violations it would
  catch do not exist: `lib/doctrans/` references `DoctransWeb` in exactly three places, all correct
  (PubSub/Endpoint broadcasts); `Doctrans.Repo` is never called from web code; no schema module is used
  directly from a LiveView or controller. Against that, boundary 0.10.4 last released September 2024, its
  upstream CI has **no version matrix at all** and is pinned to Elixir 1.15.4, and a tracer
  misclassification regression landed at Elixir 1.19 and survives on 1.20 unreported — bisected during this
  review, narrow in blast radius and harmless to this codebase, but invisible to anyone watching. Taking a
  compiler-tracer dependency with no upper version bound to re-assert facts a `grep` already confirms is the
  wrong trade for a single-maintainer project.
  Adopt the native gate instead: `mix xref graph --format cycles --label compile-connected --fail-above 0`
  as a pre-commit hook. It ships with Elixir, so it has no compatibility surface of its own. Confirm the
  baseline is zero before enabling.
  Implemented. The baseline was **not** zero: one cycle of eleven modules spanning `documents.ex`,
  both job modules and the whole of `processing/`, held together by a single compile edge —
  `worker.ex:17-18`, where `@document_id_key DocumentExtractionJob.document_id_key()` and its page
  counterpart read a constant from the job module at compile time. (The item described those two lines as
  an "unsupervised reschedule"; that is a mis-transcription. The reschedule at `worker.ex:211-218` is a
  real but separate defect, owned by Q03, and is untouched here.) One compile-time call to a job module
  made every module that job reaches at runtime recompile together. The fix states the keys once in a
  dependency-free `Doctrans.Jobs.Keys` — the same centralisation the accessors were added for (#55),
  without the compile edge that attempt introduced. Every producer and consumer of those two Oban
  argument keys now reads them from `Keys`, since a register with copies elsewhere is not one: both job
  modules, `worker.ex`, `startup_recovery.ex` (two `fragment/1` templates and one job-args map),
  `run.ex` (three `fragment/1` templates and `args/1`, the producer feeding
  `DocumentExtractionJob.new/1`), and `run_cleanup_job.ex`'s `perform/1` pattern match. The two sites
  that built `LlmProcessingJob`'s argument map by hand — `document_reprocessing.ex:106` and
  `startup_recovery.ex:134` — now call `LlmProcessingJob.page_args/3`, so the job states the shape of
  its own arguments once and the enqueue sites cannot drift from the consumer. The `"page_id"` at `document_reprocessing.ex:121`
  is deliberately **not** folded in: it keys a chat-session `retrieved_context` entry, a different
  register that happens to share a name, as are the raw-SQL result columns in `search.ex`.
  The three `chat.ex` queries moved behind the context: page revision lookup is
  `Documents.page_content_state/1` and `embeddings_ready?/1` now lives in `Doctrans.Documents`, where its
  two counting queries became `Repo.exists?`. `Doctrans.Chat` retains both public functions and no longer
  imports `Ecto.Query` or names `Doctrans.Repo` at all. `book.ex` is renamed to `document.ex`.
  Acceptance: full `mix precommit` green with the hook enabled. Verified the gate is not passing vacuously
  by adding one compile-time call to `LlmProcessingJob` back into `worker.ex`, which reproduces the same
  eleven-module cycle and fails the hook.

- [x] **G17 · P3 · Prefer the settings toggle over a new secret-scanning tool.**
  The reference report's gitleaks recommendation is largely redundant here and partly outdated. GitHub
  secret scanning **and push protection** are already enabled on this repository, which blocks a
  provider-pattern secret before it reaches the remote — strictly stronger than a post-hoc CI job — and
  pre-commit already runs `detect-private-key` (`.pre-commit-config.yaml:26`). Gitleaks upstream now
  declares itself feature-complete, security-patches-only, with development moved to a successor project,
  so adopting it would add a frozen dependency.
  The stated remedy — enable `secret_scanning_non_provider_patterns` — **turned out not to be available on
  this repository**, so the item's premise was wrong and nothing was enabled. `PATCH /repos/{owner}/{repo}`
  returns `200 OK` and leaves the field `disabled`, across three attempts (the single field, the field with
  its `secret_scanning` siblings restated, and a form-encoded variant); the token carries `repo` scope and
  no code-security configuration is attached. The setting is also absent from the UI: Settings → Advanced
  Security → Secret Protection offers only Secret Protection and Push protection, with no "Generic
  patterns" row. GitHub documents generic-pattern scanning for organization-owned repositories on GitHub
  Team with Secret Protection enabled, and this is a public repository on a personal account. A silent
  `200` on an unavailable field is the same class of hazard the phase is about: had the toggle been
  recorded as enabled from the API response alone, this register would have carried a gate that does not
  exist.
  The residual exposure is narrower than the item assumed. `openai_api_key` is a supported provider
  pattern **with** push protection, so this project's actual credential is covered; what remains uncovered
  is a self-invented token format, a connection string, or a bare HTTP authentication header. That gap is
  accepted rather than filled with a scanner, for the reasons above and because a generic scanner is
  weakest on exactly those shapes. `secret_scanning_validity_checks` remains disabled and is out of scope:
  it tests whether a found credential is live, which changes nothing about detection, and GitHub does not
  support it for generic patterns anyway.
  Implemented: the finding, the three settings the gate rests on, the unavailable one, its re-check
  command, and the fixture-false-positive procedure are recorded in `docs/CONTRIBUTING.md` under "Secret
  scanning". No scanner and no configuration were added.
  Acceptance: no secret-scanning tool is owned by this repository, and the platform gate's real coverage
  and its one hole are written down rather than assumed. Verified: `gh api repos/sapientpants/doctrans
  --jq '.security_and_analysis'` reports `secret_scanning` and `secret_scanning_push_protection` enabled,
  `secret_scanning_non_provider_patterns` disabled and unsettable. Re-open only if the repository moves to
  an organization, where the toggle becomes available.

- [x] **G18 · P3 · Reconcile the spec policy with reality.**
  `.credo.exs` disabled `Readability.Specs` with the comment "Specs are enforced by Dialyzer, not Credo".
  That is false: Dialyzer never requires a spec to exist — it infers success typings and checks only the
  specs present. Measured: 78 `@spec` against 499 public `def` in `lib/`, roughly 30% coverage even crediting
  all 73 `@impl` callbacks. `Doctrans.Documents` had 18 public functions and zero specs, which is the same
  context whose nonexistent `.t()` type G02 found in six orchestrator specs.
  Implemented: the check is enabled, scoped to `lib/doctrans/`, and the backlog it reported is gone.
  `lib/doctrans_web/` stays out: its 36 HEEx function components would take low-value specs on assigns maps.
  The comment now states the actual division of labour rather than a justification for the mute.
  The backlog was 140 findings across 32 files. 133 are answered by a written `@spec`; the other seven are
  behaviour callbacks (`PdfExtractor`'s six, `Embedding.generate/2`) that were missing `@impl true`, so the
  contract already existed in the behaviour and the compiler now checks the implementation against it.
  Eight types were added or named where the specs needed them to say anything: `Chat.message/0`,
  `Chat.Grader.grade/0`, `Chat.Agent.event/0`, `Search.Chunker.chunk/0`, `Processing.SSECollector.t/0`,
  `Processing.StartupRecovery.cursor/0`, `Resilience.HealthCheck.results/0`, and `@type t` on the `Chunk`
  and `Message` schemas.
  Writing the specs is what made Dialyzer check these functions at all, and it immediately found six defects
  the inferred typings had hidden. Five are discarded error results — `report_missing_source/1`,
  `document_orchestrator.ex:281` and `:308`, `document_processor.ex:104`, `pdf_processor.ex:56` all threw
  away an `update_document_status/3` result that can be `{:error, _}`; each is now an explicit `_ =`.
  The sixth is a pre-existing false spec of exactly this item's kind: three `pages.ex` specs said
  `Uniq.UUID.t()`, which is `<<_::128>>` — the raw 128-bit UUID — while every caller passes the 36-character
  string form. Dialyzer had no reason to object until `Run.retry_pending?/1` gained a spec and inherited the
  raw-binary typing through `failed_pages_query/1`. All three now say `Ecto.UUID.t()`.
  Acceptance: `mix credo --strict` reports no issues with the check enabled, so a new public function in
  `lib/doctrans/` fails the gate until it is specified; `mix dialyzer --list-unused-filters` passes with the
  register unchanged at 26 skips and 0 unused filters, which is what validates the 133 new specs;
  `mix test` is green at 846 tests.

- [x] **G19 · P3 · Minor CI and container hygiene.**
  Add a `concurrency` group with `cancel-in-progress` so superseded pushes stop burning a full run. Change
  the dependency cache's `actions/cache/save` from `if: always()` to `if: success()` so a half-compiled
  `_build` is not cached. Pin `Dockerfile.dev:2` (`FROM elixir:1.20.4-otp-29`) by digest and add
  `--check-locked` to its `mix deps.get`, since `Dockerfile.dev` is what `docker compose up` actually runs
  and is therefore the shipped artifact. Remove `/coveralls.json` from `.gitignore`, where it contradicts the
  tracked file.
  Container CVE scanning was considered and **rejected**: nothing is released — there is no production
  Dockerfile, no `rel/`, no registry push — so image scanning would surface base-image noise that cannot be
  actioned for a loopback-only app.
  Implemented, with one addition and one correction to the item as written. The concurrency group is
  `${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}`, not workflow-and-ref: a schedule run
  and a push to `main` report the same `github.ref`, so a ref-only group would let the weekly advisory
  re-audit cancel — or be cancelled by — an unrelated push, which is precisely the run that must not be
  silently dropped. Only the dependency cache's save moves to `if: success()`; the PLT cache keeps
  `if: always()` deliberately, because it is written by its own `mix dialyzer --plt` step that either
  succeeds before any check runs or fails the job, so there is no partial state for a later run to restore.
  The addition is a `docker` ecosystem entry in `.github/dependabot.yml`: a digest pin nothing bumps only
  trades a mutable tag for a frozen, ageing base image, and the same reasoning already justifies the
  `github-actions` entry that keeps G13's SHA pins current. Dependabot's docker file fetcher matches any
  filename containing "dockerfile" (`DOCKER_REGEXP = /dockerfile|containerfile/i`), so `Dockerfile.dev` is
  in scope and the tag and digest are rewritten together — the tag stays in the reference for readability
  and must remain in step with `mise.toml`.
  The `.gitignore` entry was not merely redundant: `coveralls.json` is excoveralls' **configuration** file
  — it carries the 80% `minimum_coverage` gate and the `skip_files` register — not an artifact, so the
  "Excoveralls artifacts" rule described it wrongly and would have hidden an edit to the coverage gate from
  anyone who cloned and re-added it.
  The digest also had to be taught to `scripts/check_toolchain_pins.exs`, which compared the whole `FROM`
  reference against `mise.toml` and so failed on the pin it was meant to protect. It now splits the
  reference, compares the tag exactly as before, and additionally **requires** a well-formed
  `@sha256:<64 hex>` digest — a bump that silently drops the pin is now a failure rather than a pass. What
  the digest names cannot be checked without a registry, and this hook stays offline.
  Acceptance: full `mix precommit` green. Both workflow files parse; the pinned digest `sha256:321ba132…`
  is the multi-architecture index, so it resolves on `ubuntu-latest` and Apple silicon alike, verified by
  running `mix deps.get --check-locked` inside a container started from that digest, which exits 0 against
  the current lockfile. The extended pin hook was verified non-vacuous against three mutations — tag
  without digest, malformed digest, and a wrong Elixir version carrying a valid digest — each of which
  exits 1 with its own message. The `Verify Docker Build` job builds `Dockerfile.dev` on every run, so the
  digest and the new flag are gated by CI rather than by assertion.

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
