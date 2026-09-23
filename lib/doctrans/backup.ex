defmodule Doctrans.Backup do
  @moduledoc """
  Reports whether the database and the storage root still describe one library.

  A backup of this application is two halves — a Postgres dump and a copy of the
  storage root — and neither half records anything about the other. Restoring
  them is an act of faith unless something checks the join afterwards, and only
  the application can check it: the rows name the files, and only the app knows
  how a row's path is rebuilt from the current root
  (`Doctrans.Processing.Run.source_path/1` for a retained original, `image_path`
  relative to the root for a page image).

  `verify/0` is that check. It is a *report, never a repair*: it creates, moves
  and deletes nothing, so it is safe to point at a restored volume before the
  application is allowed anywhere near it.

  ## Why the two directions are not symmetric

  A disagreement can run either way, and the two are not equally bad:

  - `missing` — a row whose file is absent. Unrecoverable. Nothing can invent a
    retained PDF or a page image back into existence, so the document stays dead
    weight until someone re-uploads it.
  - `extra` — a file under the root that no row owns. Harmless.
    `Doctrans.Documents.Sweeper` reclaims an orphaned document directory on a
    later pass, and until then it costs only disk.

  So `complete?` tracks `missing` alone: extras never make a restore incomplete.
  That asymmetry is also the argument for an order when taking a backup — **dump
  the database first, copy the files second**. Work that lands in the window
  between the two halves then appears as a file nobody claims, the recoverable
  direction. Taken the other way round, the same window produces rows pointing at
  files the copy never saw, which no tool can repair.

  Every path in the report is cited relative to the root, so two reports of the
  same library are comparable across roots and a log never carries an operator's
  absolute layout.
  """

  import Ecto.Query

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @typedoc "The verdict on one storage root, with both directions of disagreement listed."
  @type report :: %{
          root: String.t(),
          documents: non_neg_integer(),
          pages: non_neg_integer(),
          complete?: boolean(),
          missing: [Doctrans.Errors.reason()],
          extra: [Doctrans.Errors.reason()]
        }

  @doc """
  Compares every document and page row against the files under the storage root.

  Both lists are ordered deterministically — `missing` by document id, `extra` by
  path — so two runs over an unchanged library produce output that can be diffed.
  """
  @spec verify() :: report()
  def verify do
    # Resolved on every call rather than memoized, like `Uploads.upload_dir/0`
    # itself: the report has to describe the root the running application would
    # use, not one captured when this module was first loaded.
    root = Uploads.upload_dir()

    documents = Repo.all(documents_query())
    page_paths = Repo.all(pages_query())
    images = Enum.group_by(page_paths, &elem(&1, 0), &elem(&1, 1))

    missing =
      documents
      |> Enum.sort_by(& &1.id)
      |> Enum.flat_map(&document_reasons(&1, root, Map.get(images, &1.id, [])))

    %{
      root: root,
      documents: length(documents),
      pages: length(page_paths),
      complete?: missing == [],
      missing: missing,
      extra: extra(root, MapSet.new(documents, & &1.id))
    }
  end

  @doc """
  Renders a report as the lines an operator reads, most significant first.

  The rendering lives here rather than in whatever prints it, because a restore
  is verified from two places that cannot share code any other way: `mix
  verify_restore` in a source checkout, and `bin/verify_restore` in a release,
  where there is no Mix at all.
  """
  @spec lines(report()) :: [String.t()]
  def lines(report) do
    List.flatten([
      "Storage root: #{report.root}",
      "Checked #{report.documents} document(s) and #{report.pages} page(s).",
      Enum.map(report.missing, &"missing: #{inspect(&1)}"),
      Enum.map(report.extra, &"extra: #{inspect(&1)}"),
      verdict(report)
    ])
  end

  defp verdict(%{complete?: true} = report),
    do: "The database and #{report.root} agree."

  # Counted by document, not by reason: one document can be missing both its
  # retained original and its page images, and reporting that as two would
  # overstate how much of the library a restore actually lost.
  defp verdict(report) do
    documents =
      report.missing
      |> Enum.map(fn {_code, bindings} -> bindings[:document_id] end)
      |> Enum.uniq()
      |> length()

    "#{documents} document(s) name files that are not under #{report.root}."
  end

  # Only the fields `Run.source_path/1` rebuilds a path from. The whole library
  # is read in one pass, so a row is kept as narrow as the question allows.
  defp documents_query do
    from(d in Document,
      select: struct(d, [:id, :original_filename, :source_extension, :processing_run_id])
    )
  end

  # One pass over the pages too: a query per page would be a query per page image.
  defp pages_query, do: from(p in Page, select: {p.document_id, p.image_path})

  defp document_reasons(document, root, image_paths) do
    source_reason(document, root) ++ page_images_reason(document, root, image_paths)
  end

  defp source_reason(document, root) do
    path = Run.source_path(document)

    cond do
      # A format whose original the app never retains names no file to compare.
      is_nil(path) -> []
      Run.source_available?(document) -> []
      true -> [{:source_missing, [document_id: document.id, path: relative(path, root)]}]
    end
  end

  # Aggregated to one reason per document rather than one per page: a library
  # restored without its files would otherwise report a line for every page image
  # it has ever rendered, which no operator can read.
  defp page_images_reason(document, root, image_paths) do
    # A page with no recorded image path has not been rendered yet, so it names
    # no file the backup could have lost.
    recorded = Enum.reject(image_paths, &is_nil/1)
    missing = Enum.count(recorded, &(not File.regular?(Path.join(root, &1))))

    if missing == 0 do
      []
    else
      [{:page_images_missing, [document_id: document.id, missing: missing, of: length(recorded)]}]
    end
  end

  defp relative(path, root), do: Path.relative_to(path, root)

  defp extra(root, document_ids) do
    case File.ls(Path.join(root, "documents")) do
      {:ok, entries} ->
        entries
        # An entry name is whatever the filesystem holds — a stray file, a
        # half-copied directory — so it is compared as a plain string and never
        # parsed into a UUID or an atom.
        |> Enum.reject(&MapSet.member?(document_ids, &1))
        |> Enum.sort()
        |> Enum.map(&{:orphaned_document_dir, [path: Path.join("documents", &1)]})

      # A root with no `documents/` directory has simply never held one; that is
      # consistent with an empty library, not a failure to read the root.
      {:error, _reason} ->
        []
    end
  end
end
