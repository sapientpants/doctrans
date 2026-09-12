defmodule Doctrans.Jobs.DocumentExtractionJob do
  @moduledoc """
  Job for extracting document pages in the background.

  This job processes documents (PDF, Word, etc.) and extracts individual pages
  as images for further processing. For non-PDF formats, the document is first
  converted to PDF before extraction.
  """

  use Oban.Worker,
    queue: :pdf_extraction,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.Keys
  alias Doctrans.Processing.DocumentProcessor
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @document_id_key Keys.document_id()

  @spec enqueue_document(Ecto.UUID.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Doctrans.Errors.reason()}
  def enqueue_document(document_id, file_path) do
    Repo.transaction(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)

      # This is the stored upload path, whose extension passed magic-byte validation.
      extension = file_path |> Path.extname() |> String.downcase()

      unless extension in ~w(.pdf .doc .docx .odt .rtf),
        do: Repo.rollback({:unsupported_format, [format: extension]})

      document =
        document
        |> Ecto.Changeset.change(source_extension: document.source_extension || extension)
        |> Repo.update!()

      document =
        if document.processing_run_id do
          document
        else
          document |> Ecto.Changeset.change(Run.new_attrs()) |> Repo.update!()
        end

      case Run.args(document)
           |> Map.put("file_path", file_path)
           |> new()
           |> Oban.insert() do
        {:ok, job} -> job
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Doctrans.Errors.result()
  end

  @impl true
  def perform(%Oban.Job{args: %{@document_id_key => document_id} = args}) do
    case Documents.get_document(document_id) do
      nil -> {:error, :document_not_found}
      document -> perform_current(document, args)
    end
  end

  defp perform_current(document, args) do
    if Run.current?(document, Map.get(args, "run_id")) do
      extract_from(document, source_path(document, args))
    else
      :ok
    end
  end

  defp source_path(document, args) do
    if document.processing_run_id,
      do: Run.source_path(document),
      else: Map.get(args, "file_path") || Run.source_path(document)
  end

  defp extract_from(document, path) do
    if path && File.regular?(path) do
      case DocumentProcessor.extract_document(document.id, path, MapSet.new(), document) do
        {:error, :obsolete_run} -> :ok
        result -> result
      end
    else
      report_missing_source(document)
    end
  end

  defp report_missing_source(document) do
    _ =
      with {:ok, updated} <-
             Documents.update_document_status(document, "error", :document_file_not_found) do
        Topics.broadcast_document_update(updated)
      end

    {:error, :document_file_not_found}
  end
end
