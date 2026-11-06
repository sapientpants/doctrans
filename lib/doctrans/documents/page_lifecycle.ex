defmodule Doctrans.Documents.PageLifecycle do
  @moduledoc """
  The page stage machine: every status a page's processing stages can hold,
  and the named transitions between them.

  A page has three stages of its own -- extraction, translation and embedding
  -- and each stage has a status. `Doctrans.Documents.Lifecycle` does for a
  document's status what this module does for a page's stages: nothing else
  writes them. The schema's general changeset does not cast a stage status, and
  every caller -- the processor, the indexer, cancellation, recovery,
  reprocessing, reindexing -- names a transition rather than a status string.

  Every transition is fenced by `Doctrans.Documents.Revision.with_page/2`: the
  write lands only while the page still holds the content revision and
  processing generation the caller loaded, and answers `{:error, :obsolete_run}`
  otherwise, logging the refusal as a document transition does. Callers that
  already hold the document lock lose nothing by it, and callers that do not
  never have to take it. A transition announces `page_updated` once the write
  has committed -- right away, or, inside a caller's
  `Doctrans.Repo.safe_transaction/1`, when that transaction commits -- so no
  caller announces a stage change itself.

  ## Statuses

  | status       | meaning                                                |
  |--------------|--------------------------------------------------------|
  | `pending`    | the stage has not started, or was released or reset    |
  | `processing` | a job is working on the stage                          |
  | `completed`  | the stage finished and its product is stored           |
  | `error`      | the stage's last attempt failed                        |

  ## Transitions

  | transition       | to          | writes                                           |
  |------------------|-------------|--------------------------------------------------|
  | `begin/2`        | processing  | the status                                       |
  | `complete/3`     | completed   | the status and the stage's product               |
  | `fail/2`         | error       | the status                                       |
  | `release/1`      | pending     | every `processing` content stage; the rest kept  |
  | `resume/2`       | pending     | the given stages not `completed`; the rest kept  |
  | `forget_index/1` | pending     | the embedding stage: no chunks, no vector        |
  | `reset/2`        | pending     | every stage, a new generation, no content, index |

  There is no legal-from table: a retried job may begin a stage from `pending`,
  `processing` or `error` alike, and a stage with nothing to do may complete
  without beginning. The guard that matters is obsolete work -- a page reset,
  replaced or deleted under the caller -- and the fence refuses that in every
  transition. `complete/3` requires the stage's product, so a stage cannot be
  completed without saying what it produced: `original_markdown` for
  extraction, `translated_markdown` for translation, the page-level vector for
  embedding. An empty product is legal and must still be said: an empty
  markdown is stored as `nil`, the column's empty value, as the schema casts an
  empty string, and a page with nothing to embed completes with `embedding: nil`
  -- stated, not omitted, because global semantic search ranks on that vector
  and a page marked indexed by mistake would silently never be found.

  `release/1` is the rule for a stage nobody is working on any more: the job
  that held it `processing` is gone with the cancellation, so the stored value
  would show a spinner for work nobody is doing. Only those markers move; a
  stage that finished or failed keeps its verdict and everything it produced,
  so a cancelled document still offers to retry its failed pages. It takes a
  whole document, set-based.

  `resume/2` is the rule for a page whose owed work is queued again under its
  current generation: every given stage that has not completed -- interrupted
  or failed -- goes back to `pending`, so the page reads as queued rather than
  as failed while its retry waits, and a completed stage keeps its product. The
  stages are the ones the job being queued will redo: the content stages for a
  recovered page job (the default), the embedding stage for a re-queued
  indexing job. It is to a page what `Lifecycle.resume/1` is to a document.

  `forget_index/1` throws the page's index away -- its chunks, its page-level
  vector, its embedding status -- so the next indexing run starts from scratch
  rather than keeping every chunk that already carries a vector. The content
  revision is not touched: the page's text has not changed.

  `reset/2` starts the page over for a reprocess: a new processing generation,
  so work queued under the old one is obsolete; no content, no models, no
  index, every stage `pending`; and the models the user asked for recorded as
  `requested_*`, where the next run reads them.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Doctrans.Documents.{Chunk, Document, Page, Revision, Topics}
  alias Doctrans.Repo

  @typedoc "A stage of a page's work."
  @type stage :: :extraction | :translation | :embedding

  @typedoc """
  What completing a stage stores: for a content stage the markdown it produced
  and the model that produced it; for the embedding stage the page-level
  vector.

  `:model` is stored as given, `nil` included, so a caller that completes a
  content stage without naming a model clears the one an earlier attempt
  recorded. Leave the key out to keep it.
  """
  @type product ::
          %{required(:markdown) => String.t(), optional(:model) => String.t() | nil}
          | %{required(:embedding) => Pgvector.t() | [float()] | nil}

  @typedoc """
  The page fields a stage owns: its status, its product -- the markdown of a
  content stage, the vector of the embedding stage -- and, for a content
  stage, the model that produced it.
  """
  @type fields :: %{
          required(:status) => atom(),
          required(:product) => atom(),
          optional(:model) => atom()
        }

  @typedoc "The models a reprocess asks for; either may be absent."
  @type choices :: %{
          optional(:extraction_model) => String.t() | nil,
          optional(:translation_model) => String.t() | nil
        }

  @typedoc "The reason a transition was refused."
  @type refusal :: :obsolete_run

  @stages [:extraction, :translation, :embedding]
  @content_stages [:extraction, :translation]

  @fields %{
    extraction: %{
      status: :extraction_status,
      product: :original_markdown,
      model: :extraction_model
    },
    translation: %{
      status: :translation_status,
      product: :translated_markdown,
      model: :translation_model
    },
    embedding: %{
      status: :embedding_status,
      product: :embedding
    }
  }

  # A processing stage goes back to pending; any other value is kept as it is.
  @released "CASE WHEN ? = 'processing' THEN 'pending' ELSE ? END"

  @doc "The page fields the stage owns, so no caller spells a column name per stage."
  @spec fields(stage()) :: fields()
  def fields(stage) when stage in @stages, do: Map.fetch!(@fields, stage)

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  @doc "True once the stage has completed."
  @spec done?(Page.t(), stage()) :: boolean()
  def done?(page, stage) when stage in @stages, do: status(page, stage) == "completed"

  @doc """
  True while the stage still has work to do: it has not started, was left
  `processing` by an interrupted job, or failed.
  """
  @spec owed?(Page.t(), stage()) :: boolean()
  def owed?(page, stage) when stage in @stages, do: not done?(page, stage)

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc "Marks the stage `processing`."
  @spec begin(Page.t(), stage()) :: {:ok, Page.t()} | {:error, refusal()}
  def begin(%Page{} = page, stage) when stage in @stages do
    transition(page, :begin, &Page.stage_changeset(&1, %{fields(stage).status => "processing"}))
  end

  @doc """
  Marks the stage `completed` and stores its product in the same write.

  A product without `:markdown` for a content stage, or without `:embedding`
  for the embedding stage, matches no clause: a stage cannot be completed with
  nothing to show for it.
  """
  @spec complete(Page.t(), stage(), product()) :: {:ok, Page.t()} | {:error, refusal()}
  def complete(%Page{} = page, :embedding, %{embedding: vector}) do
    fields = fields(:embedding)
    changes = %{fields.status => "completed", fields.product => vector}
    transition(page, :complete, &Page.stage_changeset(&1, changes))
  end

  def complete(%Page{} = page, stage, %{markdown: markdown} = product)
      when stage in @content_stages and is_binary(markdown) do
    fields = fields(stage)

    changes =
      %{fields.status => "completed", fields.product => markdown}
      |> put_model(fields, product)

    transition(page, :complete, &Page.stage_changeset(&1, changes))
  end

  @doc "Marks the stage `error`, keeping whatever an earlier attempt produced."
  @spec fail(Page.t(), stage()) :: {:ok, Page.t()} | {:error, refusal()}
  def fail(%Page{} = page, stage) when stage in @stages do
    transition(page, :fail, &Page.stage_changeset(&1, %{fields(stage).status => "error"}))
  end

  @doc """
  Returns every `processing` content stage of the document's pages to
  `pending`, keeping everything else, in one statement under the document
  lock. Answers the pages it changed.
  """
  @spec release(Document.t()) :: {:ok, [Page.t()]} | {:error, refusal()}
  def release(%Document{} = document) do
    Revision.with_current(document, fn current ->
      {_count, pages} =
        from(p in Page,
          where: p.document_id == ^current.id,
          where: p.extraction_status == "processing" or p.translation_status == "processing",
          update: [
            set: [
              extraction_status: fragment(@released, p.extraction_status, p.extraction_status),
              translation_status: fragment(@released, p.translation_status, p.translation_status)
            ]
          ],
          select: p
        )
        |> Repo.update_all([])

      {:ok, pages}
    end)
    |> publish_all(document)
  end

  @doc """
  Returns each of `stages` that has not completed to `pending`, from the stages
  the page holds once locked -- not the copy the caller read, which a job may
  have finished since. The default is the two content stages.
  """
  @spec resume(Page.t(), stage() | [stage()]) :: {:ok, Page.t()} | {:error, refusal()}
  def resume(%Page{} = page, stages \\ @content_stages) do
    fields = stages |> List.wrap() |> Enum.map(&fields/1)

    transition(page, :resume, fn current ->
      Page.stage_changeset(
        current,
        Map.new(fields, &{&1.status, resumed(Map.fetch!(current, &1.status))})
      )
    end)
  end

  @doc """
  Throws the page's index away: deletes its chunks, drops its page-level vector
  and returns its embedding stage to `pending`, under the fence.
  """
  @spec forget_index(Page.t()) :: {:ok, Page.t()} | {:error, refusal()}
  def forget_index(%Page{} = page) do
    transition(page, :forget_index, fn current ->
      forget_chunks(current)
      Page.stage_changeset(current, %{embedding_status: "pending", embedding: nil})
    end)
  end

  @doc """
  Starts the page over under a new processing generation, recording the models
  `choices` ask for as the ones its next run should use.
  """
  @spec reset(Page.t(), choices()) :: {:ok, Page.t()} | {:error, refusal()}
  def reset(%Page{} = page, choices \\ %{}) do
    transition(page, :reset, fn current ->
      forget_chunks(current)
      Page.reset_changeset(current, choices)
    end)
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # One shape for every page transition: fence the write behind the revision
  # and generation the caller loaded, build the changeset from the row as
  # locked -- so a transition that depends on what the page holds now reads
  # that, not the caller's copy, and one that discards the page's chunks does
  # so under the same lock -- write it, then announce the page once it is
  # committed, or say why nothing was written. The changeset is built from
  # statuses this module names and fields the schema owns, so the only way the
  # update can fail is a lost connection, which raises here as it would
  # anywhere else.
  defp transition(page, name, changeset) when is_function(changeset, 1) do
    page
    |> Revision.with_page(fn current -> {:ok, current |> changeset.() |> Repo.update!()} end)
    |> publish(page, name)
  end

  # Called after the fence's transaction returns; a caller's enclosing
  # transaction defers the announcement to that commit, so subscribers read
  # committed state. A refusal is logged and passed through unannounced.
  defp publish({:ok, page} = result, _page, _name) do
    Repo.after_commit(fn -> Topics.broadcast_page_updated(page) end)
    result
  end

  defp publish({:error, refusal} = result, page, name) do
    Logger.info("Refused #{name} for page #{page.id}: #{refusal}")
    result
  end

  defp publish_all({:ok, pages} = result, _document) do
    Enum.each(pages, &publish({:ok, &1}, &1, :release))
    result
  end

  defp publish_all({:error, refusal} = result, document) do
    Logger.info("Refused release for document #{document.id}: #{refusal}")
    result
  end

  defp resumed("completed"), do: "completed"
  defp resumed(_status), do: "pending"

  # Only under the page lock: the delete and the next run's re-insert must not
  # be visible to a concurrent indexing run as an empty page.
  defp forget_chunks(page) do
    _ = from(c in Chunk, where: c.page_id == ^page.id) |> Repo.delete_all()
    :ok
  end

  defp status(page, stage), do: Map.fetch!(page, fields(stage).status)

  defp put_model(changes, fields, %{model: model}), do: Map.put(changes, fields.model, model)
  defp put_model(changes, _fields, _product), do: changes
end
