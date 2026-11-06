defmodule Doctrans.Processing.PageWork do
  @moduledoc """
  One Page's content work, from the queue to the Settle of its Document.

  Page work is queued from three places -- Extraction as each page is
  rendered, a Reprocess or Retry failed pages when the user asks, Recovery
  when a boot finds pages still owed -- and the three used to agree only by
  restating the job's shape, priority and uniqueness semantics. `queue/3` is
  now the one statement of them: the caller says what kind of work this is,
  and the kind decides the rest.

  | kind         | queued by                         | priority             | and then                                  |
  |--------------|-----------------------------------|----------------------|-------------------------------------------|
  | `:fresh`     | Extraction, as a page is rendered | ordinary             | nothing                                   |
  | `:requested` | Reprocess, Retry failed pages     | ahead of fresh pages | nothing: the caller reset the page        |
  | `:recovered` | Recovery, at boot                 | ordinary             | marks the job `recovered` and resumes the page |

  A recovered page was interrupted mid-stage, so once its job is queued the
  content stages that job will redo go back to `pending` through
  `PageLifecycle.resume/1`: the page reads as queued, not as stuck or failed,
  while its retry waits. A requested page needs no such step, because the
  reset that preceded it already returned every stage to `pending`.

  Which models the job carries is one rule for every kind, `Run.page_model_args/2`:
  the models the Page requested, else the Document's, else none, leaving the
  defaults to the attempt. A reset writes the user's choices on the Page, so a
  requested page carries them without the caller encoding them again.

  `queue/3` opens no transaction and takes no lock. Extraction queues under the
  Run fence, a Reprocess, a Retry and Recovery under the Document lock, and the job
  commits with whatever its caller's transaction commits. The generation the
  job carries is the one the Page holds as it is handed in, so the caller
  passes the Page it has just read or written.
  """

  require Logger

  alias Doctrans.Documents.{Document, Page, PageLifecycle}
  alias Doctrans.Errors
  alias Doctrans.Jobs.{Keys, LlmProcessingJob}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @typedoc "Who is asking for the work, which decides how the job is queued."
  @type kind :: :fresh | :requested | :recovered

  @typedoc """
  What became of the request.

  - `:queued` -- the job is in the queue
  - `:owned` -- an active job already holds this page; it is that job's to finish
  - `:not_owed` -- both content stages are complete, so there is nothing to queue
  """
  @type outcome :: {:ok, :queued | :owned | :not_owed} | {:error, Errors.reason()}

  @doc """
  Queues the Page's content work as the given `kind` of request.

  Uniqueness on the page keeps one job per Page: a request for a Page an
  active job already holds answers `{:ok, :owned}` and changes nothing. What
  that means is the caller's to say -- Extraction carries on, a Reprocess
  refuses, Recovery leaves the page's stages to the job that owns them.
  """
  @spec queue(Page.t(), Document.t(), as: kind()) :: outcome()
  def queue(%Page{} = page, %Document{} = document, as: kind)
      when kind in [:fresh, :requested, :recovered] do
    if owed?(page) do
      Logger.info("Queueing page #{page.page_number} of document #{document.id} (#{kind})")

      page
      |> args(document)
      |> LlmProcessingJob.new(options(kind))
      |> Repo.insert_job()
      |> case do
        {:ok, %Oban.Job{}} -> follow_up(kind, page)
        {:conflict, %Oban.Job{}} -> {:ok, :owned}
        {:error, _reason} = error -> Errors.result(error)
      end
    else
      {:ok, :not_owed}
    end
  end

  # Queue first, then resume: uniqueness also covers a job queued since the
  # page was selected, and a job that already owns the page owns its stages.
  defp follow_up(:recovered, page) do
    with {:ok, _resumed} <- PageLifecycle.resume(page), do: {:ok, :queued}
  end

  defp follow_up(_kind, _page), do: {:ok, :queued}

  # A page is owed work until both of its content stages have completed; the
  # embedding stage is the index pipeline's and queued separately.
  defp owed?(page) do
    not (PageLifecycle.done?(page, :extraction) and PageLifecycle.done?(page, :translation))
  end

  # Retries and resets go ahead of the pages of a fresh upload: the user is
  # waiting on them, and a fresh run's pages are already a queue of their own.
  defp options(:fresh), do: [priority: 2]
  defp options(:requested), do: [priority: 1]
  defp options(:recovered), do: [priority: 2, meta: %{recovered: true}]

  # The argument map `Doctrans.Jobs.LlmProcessingJob.perform/1` destructures.
  defp args(page, document) do
    Map.merge(
      %{
        Keys.page_id() => page.id,
        "page_number" => page.page_number,
        "generation" => page.processing_generation
      },
      Run.page_model_args(page, document)
    )
  end
end
