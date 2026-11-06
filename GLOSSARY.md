# Doctrans

A local, single-user application that turns an uploaded document into page images, extracts each page as Markdown with a
vision model, translates it, and indexes it for search and chat. One context: the document and everything that happens
to it.

## Language

### Documents and pages

**Document**:
An uploaded file being translated. It has exactly one status at a time, and that status belongs to the document, not to
its pages.

**Page**:
One rendered page of a Document, with its own extraction and translation stages and an embedding status.

**Run**:
One processing attempt of a whole Document. A newer Run makes work from an older Run obsolete.
_Avoid_: generation, revision (as a name for the run itself)

**Obsolete work**:
Work planned under a Run, or against a Page's content revision or generation, that the Document or Page no longer
holds. It is refused when it tries to write, and the attempt counts as done, not failed.

**Chunk**:
A paragraph-bounded slice of a Page's original text, embedded for retrieval.

### Document lifecycle

**Document lifecycle**:
The set of statuses a Document can hold and the named transitions between them. Every status change is one of those
transitions; there is no generic "set status".

**Transition**:
A named move of a Document from one status to another, legal only from specific starting statuses. A transition from an
illegal status is refused, not ignored.

**Terminal status**:
A status no job-side transition leaves: only the user's own request does, by starting a new Run or by
queuing Page work under the current one (reprocessing a Page, retrying failed Pages). `cancelled` and
`completed` are terminal.

**Settle**:
The transition that decides a Document's outcome once every Page has either succeeded or failed. A Document reaches
`error` from page failures only by settling, and only once.
_Avoid_: complete (as a verb for this), check completion

**Requeue**:
The transition that starts a new Run for a Document, from a fresh upload or a reprocess alike.
_Avoid_: start run, reset

**Cancellation**:
The user's decision to stop a Document's work that has not started. Work already running finishes on its own but cannot
change the Document's status afterwards.

**Failed**:
The outcome of a Document or Page whose work ended in an error. The stored status string is `error`; in prose and in
read models say failed.
_Avoid_: errored

### Processing

**Extraction**:
Converting a Document's source file to PDF when it is not one already, and rendering it into Page images. One
step of a Run; the Document's Transitions during it belong to it alone. Vision-model text extraction from a Page
image is **page extraction**, a Page stage, not this.

**Reprocess**:
Replacing a whole Run, or resetting one Page, with a chosen model.

**Retry failed pages**:
Re-queuing only the Pages that failed, within the current Run.

**Recovery**:
The pass at boot that re-queues work the previous process left owed.

**Processing status**:
The read model that reports a Document's content pipeline and index pipeline separately, with the actions it is safe to
offer.
