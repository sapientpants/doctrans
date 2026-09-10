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

  # Only fixed generated subdirectories and validated UUID run directories are removed.
  # The retained original.<extension> is never a cleanup target.
  # sobelow_skip ["Traversal.FileModule"]
  defp clean(document) do
    directory = Documents.document_upload_dir(document.id)
    runs = Path.join(directory, "runs")

    entries =
      case File.ls(runs) do
        {:ok, entries} -> entries
        {:error, :enoent} -> []
        {:error, reason} -> Doctrans.Repo.rollback(reason)
      end

    old_runs =
      Enum.filter(entries, fn entry ->
        match?({:ok, _}, Ecto.UUID.cast(entry)) && entry != document.processing_run_id
      end)

    legacy = if document.processing_run_id, do: [Path.join(directory, "pages")], else: []

    converted =
      if Path.extname(Run.source_path(document) || "") != ".pdf",
        do: [Path.join(directory, "original.pdf")],
        else: []

    paths = Enum.map(old_runs, &Path.join(runs, &1)) ++ legacy ++ converted

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.rm_rf(path) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason, _} -> {:halt, {:error, reason}}
      end
    end)
  end
end
