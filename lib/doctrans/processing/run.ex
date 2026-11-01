defmodule Doctrans.Processing.Run do
  @moduledoc "Stored source paths, model choices, and transactional processing-run guards."
  import Ecto.Query
  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents.{Document, Formats, Layout, Page, Pages}
  alias Doctrans.Jobs.{Keys, LlmProcessingJob}
  alias Doctrans.Processing.JobQuery
  alias Doctrans.Repo

  @doc """
  True while an extraction or LLM job of the document can still run.

  Indexing jobs are not counted: `EmbeddingJob` cancels itself when the
  revision it holds is superseded, so it never owns the content a reprocess
  would replace.
  """
  @spec active?(Ecto.UUID.t()) :: boolean()
  def active?(document_id) do
    document_id
    |> JobQuery.document_work_query([LlmProcessingJob])
    |> Repo.exists?()
  end

  @doc """
  True when a failed page of the document still has an active LLM job.

  A scheduled or retryable job may still turn the page into a success, so its
  failure is not terminal for the document yet.
  """
  @spec retry_pending?(Ecto.UUID.t()) :: boolean()
  def retry_pending?(document_id) do
    failed_page_ids =
      document_id
      |> Pages.failed_pages_query()
      |> select([p], type(p.id, :string))

    failed_page_ids
    |> JobQuery.page_jobs_query(worker: LlmProcessingJob)
    |> Repo.exists?()
  end

  @spec choices(keyword()) :: %{extraction_model: String.t(), translation_model: String.t()}
  def choices(opts \\ []) do
    %{
      extraction_model: Keyword.get(opts, :extraction_model) || OpenAI.vision_model(),
      translation_model: Keyword.get(opts, :translation_model) || OpenAI.translation_model()
    }
  end

  @spec new_attrs(keyword()) :: %{
          extraction_model: String.t(),
          translation_model: String.t(),
          processing_run_id: Ecto.UUID.t()
        }
  def new_attrs(opts \\ []), do: Map.put(choices(opts), :processing_run_id, Uniq.UUID.uuid7())

  @spec model_opts(Document.t()) :: keyword(String.t())
  def model_opts(document) do
    Enum.reject(
      [
        extraction_model: document.extraction_model,
        translation_model: document.translation_model
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  @spec page_model_args(Page.t(), Document.t()) :: %{String.t() => String.t()}
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

  @spec args(Document.t()) :: %{String.t() => Ecto.UUID.t() | nil}
  def args(document),
    do: %{Keys.document_id() => document.id, "run_id" => document.processing_run_id}

  @spec source_path(Document.t()) :: String.t() | nil
  def source_path(document) do
    # Older documents predate source metadata; retain their filename fallback.
    extension = document.source_extension || Formats.extension(document.original_filename)

    if Formats.supported?(extension) do
      Layout.original_path(document.id, extension)
    end
  end

  @spec source_available?(Document.t()) :: boolean()
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

  # A document without a run predates runs: its derived files sit directly in
  # its document directory, where `Doctrans.Documents.Layout` calls them legacy.
  @spec output_dir(Document.t()) :: String.t()
  def output_dir(%{processing_run_id: nil} = document), do: Layout.document_dir(document.id)
  def output_dir(document), do: Layout.run_dir(document.id, document.processing_run_id)

  @spec pages_dir(Document.t()) :: String.t()
  def pages_dir(%{processing_run_id: nil} = document), do: Layout.legacy_pages_dir(document.id)
  def pages_dir(document), do: Layout.pages_dir(document.id, document.processing_run_id)

  @spec lock(Ecto.UUID.t()) :: Document.t() | nil
  def lock(document_id) do
    from(d in Document, where: d.id == ^document_id, lock: "FOR UPDATE") |> Repo.one()
  end

  @spec current?(Document.t() | nil, Ecto.UUID.t() | nil) :: boolean() | nil
  def current?(document, run_id), do: document && document.processing_run_id == run_id

  @spec with_current(Document.t(), (Document.t() -> result)) :: result | {:error, term()}
        when result: var
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
  @spec with_page(Page.t(), (Page.t() -> result)) :: result | {:error, term()} when result: var
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
