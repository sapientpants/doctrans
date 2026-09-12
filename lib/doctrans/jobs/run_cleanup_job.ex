defmodule Doctrans.Jobs.RunCleanupJob do
  @moduledoc "Removes superseded derived files while preserving the original upload."
  use Oban.Worker, queue: :pdf_extraction, max_attempts: 5
  alias Doctrans.Documents
  alias Doctrans.Processing.Run

  @impl true
  def perform(%Oban.Job{args: %{"document_id" => id}}) do
    case Documents.get_document(id) do
      nil -> :ok
      document -> Run.with_current(document, &clean/1)
    end
  end

  defp clean(document) do
    document.id
    |> Documents.document_upload_dir()
    |> stale_paths(document)
    |> remove_all()
  end

  # Only fixed generated subdirectories and validated UUID run directories are
  # listed. The retained original.<extension> is never a cleanup target.
  defp stale_paths(directory, document) do
    runs = Path.join(directory, "runs")

    stale_run_dirs(runs, document) ++
      legacy_pages_dir(directory, document) ++ converted_pdf(directory, document)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stale_run_dirs(runs, document) do
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

  defp legacy_pages_dir(directory, document) do
    if document.processing_run_id, do: [Path.join(directory, "pages")], else: []
  end

  defp converted_pdf(directory, document) do
    if Path.extname(Run.source_path(document) || "") != ".pdf",
      do: [Path.join(directory, "original.pdf")],
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
