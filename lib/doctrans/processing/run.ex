defmodule Doctrans.Processing.Run do
  @moduledoc """
  Stored source paths, model choices, and whether a document's run is still live.

  The transactional guards (`lock/1`, `current?/2`, `with_current/2`,
  `with_page/2`) live in `Doctrans.Documents.Revision`, which owns the
  revision columns they compare; they are delegated here so the processing
  layer keeps one entry point for run concerns.
  """
  alias Doctrans.Config.OpenAI
  alias Doctrans.Documents.{Document, Formats, Layout, Page, Revision}
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

  defdelegate lock(document_id), to: Revision
  defdelegate current?(document, run_id), to: Revision
  defdelegate with_current(document, fun), to: Revision
  defdelegate with_page(page, fun), to: Revision
end
