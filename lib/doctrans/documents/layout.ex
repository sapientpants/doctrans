defmodule Doctrans.Documents.Layout do
  @moduledoc """
  The on-disk layout of the storage root, as pure path functions.

  Every file the application keeps lives under `root/0`, which is the configured
  `Doctrans.Config.Uploads.upload_dir/0`:

      documents/<document-id>/original.<ext>          the retained upload
      documents/<document-id>/runs/<run-id>/pages/    page images of one run
      documents/<document-id>/pages/                  page images from before runs existed

  Writers (`Doctrans.Documents.Intake`, `Doctrans.Processing.PdfProcessor`),
  readers (`Doctrans.Processing.LlmProcessor`), cleanup
  (`Doctrans.Jobs.RunCleanupJob`, `Doctrans.Documents.Sweeper`) and the restore
  check (`Doctrans.Backup`) all build paths through this module, so the layout is
  spelled out once. Page image filenames are deliberately not modelled here:
  `pdftoppm` names them, and `Doctrans.Processing.PdfExtractor.page_image_path/2`
  only globs for them. The URL allow-list in `DoctransWeb.Plugs.UploadImages`
  mirrors the layout on purpose; it decides what is served, not where it is.

  Nothing here touches the filesystem. The root is read on every call, like
  `Uploads.upload_dir/0`, so a root that moves at runtime moves every path with it.
  """

  alias Doctrans.Config.Uploads

  @documents "documents"
  @runs "runs"
  @pages "pages"
  @original "original"

  @doc "The storage root every other path is built beneath."
  @spec root() :: String.t()
  def root, do: Uploads.upload_dir()

  @doc "The directory that holds one subdirectory per document."
  @spec documents_dir() :: String.t()
  def documents_dir, do: Path.join(root(), @documents)

  @doc "The directory of one document: its retained upload and its runs."
  @spec document_dir(Ecto.UUID.t()) :: String.t()
  def document_dir(document_id), do: Path.join(documents_dir(), to_string(document_id))

  @doc """
  The retained upload of a document, named `original` plus its extension.

  The extension includes its leading dot (`".pdf"`), as `Doctrans.Documents.Formats`
  returns it.
  """
  @spec original_path(Ecto.UUID.t(), String.t()) :: String.t()
  def original_path(document_id, extension),
    do: Path.join(document_dir(document_id), @original <> extension)

  @doc "The directory that holds one subdirectory per processing run of a document."
  @spec runs_dir(Ecto.UUID.t()) :: String.t()
  def runs_dir(document_id), do: Path.join(document_dir(document_id), @runs)

  @doc "The directory of one processing run of a document."
  @spec run_dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def run_dir(document_id, run_id), do: Path.join(runs_dir(document_id), run_id)

  @doc "The page images of one processing run of a document."
  @spec pages_dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def pages_dir(document_id, run_id), do: Path.join(run_dir(document_id, run_id), @pages)

  @doc """
  The page images of a document processed before runs existed.

  Such a document has no `processing_run_id`; its images sit directly under the
  document directory and are removed by `Doctrans.Jobs.RunCleanupJob` once the
  document is reprocessed into a run.
  """
  @spec legacy_pages_dir(Ecto.UUID.t()) :: String.t()
  def legacy_pages_dir(document_id), do: Path.join(document_dir(document_id), @pages)

  @doc """
  Resolves a path stored relative to the root, such as a page's `image_path`.

  Page rows persist their image path relative to the root so the library can be
  restored under a different directory; this is the one place that turns such a
  path back into one the filesystem understands.
  """
  @spec absolute(String.t()) :: String.t()
  def absolute(relative_path), do: Path.join(root(), relative_path)

  @doc "The inverse of `absolute/1`: a path under the root, made relative to it."
  @spec relative(String.t()) :: String.t()
  def relative(absolute_path), do: Path.relative_to(absolute_path, root())
end
