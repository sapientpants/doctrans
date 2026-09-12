defmodule Doctrans.Processing.Run do
  @moduledoc "Stored source paths, model choices, and transactional processing-run guards."
  import Ecto.Query
  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page, Pages}
  alias Doctrans.Jobs.{DocumentExtractionJob, Keys, LlmProcessingJob}
  alias Doctrans.Repo

  @active ~w(available scheduled executing retryable suspended)
  @document_id_arg "?->>'#{Keys.document_id()}'"
  @page_id_arg "?->>'#{Keys.page_id()}'"

  def active?(document_id) do
    page_ids = from p in Page, where: p.document_id == ^document_id, select: type(p.id, :string)

    from(j in Oban.Job,
      where: j.state in ^@active,
      where:
        (j.worker == ^Oban.Worker.to_string(DocumentExtractionJob) and
           fragment(@document_id_arg, j.args) == ^document_id) or
          (j.worker == ^Oban.Worker.to_string(LlmProcessingJob) and
             fragment(@page_id_arg, j.args) in subquery(page_ids))
    )
    |> Repo.exists?()
  end

  @doc """
  True when a failed page of the document still has an active LLM job.

  A scheduled or retryable job may still turn the page into a success, so its
  failure is not terminal for the document yet.
  """
  def retry_pending?(document_id) do
    failed_page_ids =
      document_id
      |> Pages.failed_pages_query()
      |> select([p], type(p.id, :string))

    from(j in Oban.Job,
      where: j.state in ^@active,
      where: j.worker == ^Oban.Worker.to_string(LlmProcessingJob),
      where: fragment(@page_id_arg, j.args) in subquery(failed_page_ids)
    )
    |> Repo.exists?()
  end

  def choices(opts \\ []) do
    %{
      extraction_model: Keyword.get(opts, :extraction_model) || OpenAI.vision_model(),
      translation_model: Keyword.get(opts, :translation_model) || OpenAI.translation_model()
    }
  end

  def new_attrs(opts \\ []), do: Map.put(choices(opts), :processing_run_id, Uniq.UUID.uuid7())

  def model_opts(document) do
    Enum.reject(
      [
        extraction_model: document.extraction_model,
        translation_model: document.translation_model
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  def page_model_args(page, document) do
    overrides =
      Enum.reject(
        [
          extraction_model: page.requested_extraction_model,
          translation_model: page.requested_translation_model
        ],
        fn {_, value} -> is_nil(value) end
      )

    document
    |> model_opts()
    |> Keyword.merge(overrides)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  def args(document),
    do: %{Keys.document_id() => document.id, "run_id" => document.processing_run_id}

  def source_path(document) do
    # Older documents predate source metadata; retain their filename fallback.
    extension =
      document.source_extension ||
        document.original_filename |> Path.extname() |> String.downcase()

    if extension in ~w(.pdf .doc .docx .odt .rtf) do
      Path.join(Documents.document_upload_dir(document.id), "original" <> extension)
    end
  end

  def source_available?(document) do
    case source_path(document) do
      nil ->
        false

      path ->
        match?(
          {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write],
          File.stat(path)
        )
    end
  end

  def output_dir(%{processing_run_id: nil} = document),
    do: Documents.document_upload_dir(document.id)

  def output_dir(document),
    do:
      Path.join([Documents.document_upload_dir(document.id), "runs", document.processing_run_id])

  def pages_dir(document), do: Path.join(output_dir(document), "pages")

  def lock(document_id) do
    from(d in Document, where: d.id == ^document_id, lock: "FOR UPDATE") |> Repo.one()
  end

  def current?(document, run_id), do: document && document.processing_run_id == run_id

  def with_current(document, fun) do
    Repo.transaction(fn ->
      current = lock(document.id)

      if current?(current, document.processing_run_id),
        do: fun.(current),
        else: Repo.rollback(:obsolete_run)
    end)
    |> unwrap()
  end

  # A full restart creates new page IDs. Locking the parent serializes page writes
  # with replacement; checking the content revision also fences single-page resets.
  def with_page(page, fun) do
    Repo.transaction(fn ->
      document = lock(page.document_id)
      current = Repo.one(from p in Page, where: p.id == ^page.id, lock: "FOR UPDATE")

      if document && current && current.content_revision == page.content_revision &&
           current.processing_generation == page.processing_generation,
         do: fun.(current),
         else: Repo.rollback(:obsolete_run)
    end)
    |> unwrap()
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(error), do: error
end
