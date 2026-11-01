defmodule Doctrans.Jobs.RunCleanupJob do
  @moduledoc "Removes superseded derived files while preserving the original upload."
  use Oban.Worker, queue: :pdf_extraction, max_attempts: 5
  alias Doctrans.Documents
  alias Doctrans.Documents.Layout
  alias Doctrans.Jobs.Keys
  alias Doctrans.Processing.Run

  @document_id_key Keys.document_id()

  @impl true
  def perform(%Oban.Job{args: %{@document_id_key => id}}) do
    case Documents.get_document(id) do
      nil -> :ok
      document -> Run.with_current(document, &clean/1)
    end
  end

  defp clean(document) do
    document
    |> stale_paths()
    |> remove_all()
  end

  # Only fixed generated subdirectories and validated UUID run directories are
  # listed. The retained original.<extension> is never a cleanup target.
  defp stale_paths(document) do
    stale_run_dirs(document) ++ legacy_pages_dir(document) ++ converted_pdf(document)
  end

  # `runs` is a fixed subdirectory of the configured document directory, and only
  # entries that cast as UUIDs are returned.
  defp stale_run_dirs(document) do
    runs = Layout.runs_dir(document.id)

    entries =
      case File.ls(runs) do
        {:ok, entries} -> entries
        {:error, :enoent} -> []
        {:error, reason} -> Doctrans.Repo.rollback(reason)
      end

    entries
    |> Enum.filter(fn entry ->
      match?({:ok, _}, Ecto.UUID.cast(entry)) && entry != document.processing_run_id
    end)
    |> Enum.map(&Path.join(runs, &1))
  end

  defp legacy_pages_dir(document) do
    if document.processing_run_id, do: [Layout.legacy_pages_dir(document.id)], else: []
  end

  # A converted office document left its PDF beside the original before runs
  # existed; one converted inside a run is removed with that run's directory.
  defp converted_pdf(document) do
    if Path.extname(Run.source_path(document) || "") != ".pdf",
      do: [Layout.original_path(document.id, ".pdf")],
      else: []
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_all(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.rm_rf(path) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason, _} -> {:halt, {:error, reason}}
      end
    end)
  end
end
