defmodule Mix.Tasks.RechunkDocuments do
  @moduledoc """
  Rebuilds the chunks and embeddings of every extracted page.

  Run it after a change to the chunker or to the embedding model, when the
  stored chunks or vectors no longer match what a fresh index would produce. The
  task itself calls no model: for each page it clears the index under the page
  lock and queues `Doctrans.Jobs.EmbeddingJob`, which rebuilds the page in the
  running application with the same revision fencing and retry schedule as every
  other indexing run. The queued work is done by the application, so the server
  must be running (or started afterwards) for the pages to be re-indexed: the
  task boots the application with its queues closed and its startup recovery
  off, so that this short-lived VM only enqueues and never executes.

  A page an active indexing job already owns is left to that job and reported as
  skipped; rerun the task once that job has finished.

  ## Usage

      mix rechunk_documents
  """

  use Mix.Task

  alias Doctrans.Search.Reindex

  @shortdoc "Rebuild the chunks and embeddings of every extracted page"

  @impl true
  def run(_args) do
    start_app_enqueue_only()

    page_ids = Reindex.extracted_page_ids()
    total = length(page_ids)
    Mix.shell().info("Found #{total} pages to rebuild")

    counts =
      page_ids
      |> Enum.with_index(1)
      |> Enum.reduce(%{queued: 0, skipped: 0, failed: 0}, fn {page_id, index}, counts ->
        Mix.shell().info("Rebuilding page #{index}/#{total}: #{page_id}")
        Map.update!(counts, report(Reindex.rebuild_page(page_id)), &(&1 + 1))
      end)

    Mix.shell().info(
      "Done. #{counts.queued} queued, #{counts.skipped} skipped, #{counts.failed} failed."
    )
  end

  # Booted as configured, this VM would open the embedding queue and start
  # executing the very jobs the loop below queues, then halt without grace the
  # moment `run/1` returns: a job caught mid-run is left `executing` — its page
  # stuck at "processing", its revision blocked from re-enqueue — until
  # `Oban.Lifeline` rescues it a quarter of an hour later. Startup recovery is
  # also a boot-time enqueue, and a job it queues for a not-yet-indexed page would
  # make the rebuild of that page skip as owned. Both are the running server's to
  # do; this process only enqueues.
  #
  # The override is applied only when this task is the one booting the
  # application. Under `mix test` the app is already running, and a global
  # environment the suite did not set must not be changed from here.
  defp start_app_enqueue_only do
    Mix.Task.run("app.config")

    unless app_started?() do
      oban = Application.get_env(:doctrans, Oban, [])
      Application.put_env(:doctrans, Oban, Keyword.merge(oban, queues: false, plugins: false))

      worker = Application.get_env(:doctrans, Doctrans.Processing.StartupRecoveryWorker, [])

      Application.put_env(
        :doctrans,
        Doctrans.Processing.StartupRecoveryWorker,
        Keyword.put(worker, :startup_recovery, false)
      )
    end

    Mix.Task.run("app.start")
  end

  defp app_started? do
    Enum.any?(Application.started_applications(), &match?({:doctrans, _, _}, &1))
  end

  # Prints one page's outcome and names the counter it goes to.
  defp report({:ok, :queued}), do: :queued

  defp report({:skipped, reason}) do
    Mix.shell().info("  Skipped: #{inspect(reason)}")
    :skipped
  end

  defp report({:error, reason}) do
    Mix.shell().error("  Failed: #{inspect(reason)}")
    :failed
  end
end
