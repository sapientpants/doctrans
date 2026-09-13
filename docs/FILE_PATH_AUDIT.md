# File path audit

P2.17 removes the global `Traversal.FileModule` ignore. Sobelow 0.15 supports
function-local `# sobelow_skip ["Traversal.FileModule"]` comments with `skip: true`;
it does not support the plan's proposed `ignore: [{:manual, ...}]` syntax. Each
exception has a source-of-path explanation next to the function. New functions
remain scanned. Changes inside an annotated function require reviewing its paths.

## Upload boundary

`DocumentLive.Index.consume_upload_entry/2` reads the temporary path supplied by
Phoenix LiveView, independently of `entry.client_name`. The client name contributes
only `Path.extname/1`, lowercased. `Validation.validate_file_content/2` accepts only
the exact extensions `.pdf`, `.doc`, `.docx`, `.odt`, and `.rtf`, with matching magic
bytes, before any destination directory or copy is created. The destination is
`<configured uploads>/documents/<server-generated UUID>/original<extension>`.
Filename sanitization is for metadata, not the path-containment boundary.
The validated extension is persisted from the stored upload path when extraction
is queued, independently of the sanitized display filename. Older documents use
their filename extension as a compatibility fallback.

HTTP serving allows only `documents/<UUID>/pages/page-<digits>.png` and
`documents/<UUID>/runs/<UUID>/pages/page-<digits>.png`. Retained originals,
converted PDFs, and other files beneath the upload root are not served.

The LiveView regression tests exercise traversal segments, absolute paths, Windows
separators, NUL bytes, Unicode, and uppercase extensions through real uploads and
verify the bytes copied into the generated document directory.
The audit also found that NUL bytes survived into the generated title and caused a
database error. Upload metadata is now sanitized before deriving the title, and
the filename sanitizer also replaces backslashes.

## Other audited paths

| Operations | Path source and constraint |
| --- | --- |
| Document deletion and directory creation | Generated or database UUID under the configured upload root; fixed `pages` suffix. |
| Storage root creation at startup | The configured upload root itself (`DOCTRANS_DATA_DIR` or the application default); no request value contributes. |
| Page image serving | The same configured upload root, resolved per request, plus the segments the allow-list above already constrains. |
| Orphan sweeper deletion | Direct children returned by `File.ls` on the documents directory; `File.rm_rf` removes symlinks without traversing their targets. |
| Environment loading | Operator-specified `.env` path or `DOCTRANS_ENV_FILE`; intentionally outside upload storage. |
| Converter directory creation and profile cleanup | Output directory is the stored upload's parent. Profile directory is created by `mktemp`; PDF name uses `Path.basename` of the source. Executable lookup uses operator PATH directories. |
| Document/PDF processing | The retained original uses a fixed validated extension. Conversion and page output use persisted document/run UUID directories. Successful processing and cancellation preserve the original. |
| PDF extraction | Document UUID/pages directory with fixed `page` output prefix; page numbers come from the extraction loop. Globs use the same directory. The legacy `get_pdf_path/1` helper uses an internal document ID and has no production callers. |
| Image reads | `LlmProcessor` joins the configured upload root with the relative image path recorded by `PdfProcessor`, derived from extractor output. |
| Health probe | Configured upload root plus fixed prefix and server timestamp. |
| Validation header reads | LiveView temporary upload path, never the client name. |
| Failed document creation cleanup | Exact destination returned by the upload copy operation. |
| Extraction job source | Database document UUID plus `original` with the stored validated extension. An office upload is always reconverted from its original, never substituted with an older PDF. |
| Superseded-run cleanup | Fixed `pages` legacy directory and validated UUID children of `runs`, excluding the current run. Legacy converted `original.pdf` is removable only for non-PDF originals. Original uploads are never cleanup targets. |

These internal APIs assume application-generated job arguments and page records.
Operator configuration, direct database edits, and filesystem modification by other
local processes are outside the client-filename boundary; these annotations do not
claim to defend against symlink replacement races by a local filesystem writer.

To review suppressed findings again, run:

```sh
mix sobelow --config --no-skip --private --verbose
```
