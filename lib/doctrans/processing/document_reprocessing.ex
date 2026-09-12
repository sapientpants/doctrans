defmodule Doctrans.Processing.DocumentReprocessing do
  @moduledoc "Atomically replaces generated document content and starts a fresh run."
  import Ecto.Query
  alias Doctrans.Chat.Session
  alias Doctrans.Documents
  alias Doctrans.Documents.{Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob, RunCleanupJob}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @spec reprocess_document(Ecto.UUID.t(), keyword()) ::
          {:ok, Documents.Document.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_document(document_id, opts \\ []) do
    transact(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)
      ensure_reprocessable!(document, opts)
      purge_generated_content(document)
      start_run(document, opts)
    end)
    |> publish()
  end

  defp ensure_reprocessable!(document, opts) do
    if Keyword.has_key?(opts, :expected_run_id) &&
         opts[:expected_run_id] != document.processing_run_id,
       do: Repo.rollback(:obsolete_run)

    validate_models!(opts)

    if document.status not in ~w(completed error) || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    unless Run.source_available?(document), do: Repo.rollback(:original_upload_missing)
  end

  defp purge_generated_content(document) do
    _ = from(p in Page, where: p.document_id == ^document.id) |> Repo.delete_all()

    _ =
      from(s in Session, where: s.document_id == ^document.id)
      |> Repo.update_all(set: [retrieved_context: []])

    :ok
  end

  defp start_run(document, opts) do
    attrs =
      Map.merge(Run.new_attrs(opts), %{status: "queued", total_pages: nil, error_message: nil})

    document = document |> Ecto.Changeset.change(attrs) |> Repo.update!()
    _ = insert!(DocumentExtractionJob.new(Run.args(document)))
    _ = insert!(RunCleanupJob.new(Run.args(document)))
    document
  end

  @spec reprocess_page(Ecto.UUID.t(), keyword()) ::
          {:ok, Page.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_page(page_id, opts \\ []) do
    case Documents.get_page(page_id) do
      nil -> {:error, :page_not_found}
      page -> reset_page(page, opts)
    end
  end

  defp reset_page(page, opts) do
    result = transact(fn -> do_reset_page(page, opts) end)

    case result do
      {:ok, {document, page}} ->
        _ = Topics.broadcast_document_update(document)
        Topics.broadcast_page_update(page)
        {:ok, page}

      error ->
        error
    end
  end

  # The page's saved chunks are gone; leaving their text in the conversation
  # context would answer the next question from the content just discarded.
  # The document lock held here also serializes this with in-flight answers.
  defp do_reset_page(page, opts) do
    document = Run.lock(page.document_id) || Repo.rollback(:document_not_found)
    current = Repo.get(Page, page.id) || Repo.rollback(:page_not_found)
    validate_models!(opts)

    if document.status in ~w(uploading queued extracting) || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    {:ok, reset} = Documents.reset_page_for_reprocessing(current)
    _ = purge_page_context(document.id, current.id)

    choices = Run.choices(opts)
    updated = request_models(reset, choices)

    _ = insert!(LlmProcessingJob.new(page_job_args(page, updated, choices), priority: 1))
    {:ok, document} = Documents.update_document_status(document, "processing")
    {document, updated}
  end

  defp request_models(page, choices) do
    page
    |> Ecto.Changeset.change(
      requested_extraction_model: choices.extraction_model,
      requested_translation_model: choices.translation_model
    )
    |> Repo.update!()
  end

  defp page_job_args(page, updated, choices) do
    LlmProcessingJob.page_args(
      page,
      updated.processing_generation,
      LlmProcessingJob.model_args(Map.to_list(choices))
    )
  end

  defp purge_page_context(document_id, page_id) do
    from(s in Session, where: s.document_id == ^document_id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn session ->
      kept = Enum.reject(session.retrieved_context, &(&1["page_id"] == page_id))

      if length(kept) != length(session.retrieved_context) do
        Repo.update!(Ecto.Changeset.change(session, retrieved_context: kept))
      end
    end)
  end

  defp validate_models!(opts) do
    unless Enum.all?(Run.choices(opts), fn {_key, model} ->
             is_binary(model) && String.trim(model) != ""
           end),
           do: Repo.rollback(:invalid_model)
  end

  defp insert!(changeset) do
    case Oban.insert(changeset) do
      {:ok, %{conflict?: false} = job} -> job
      {:ok, _} -> Repo.rollback(:already_processing)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transact(fun) do
    Repo.transaction(fun) |> Doctrans.Errors.result()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, {:database_error, [reason: error]}}
  end

  defp publish({:ok, document}) do
    _ = Topics.broadcast_document_update(document)
    {:ok, document}
  end

  defp publish(error), do: error
end
