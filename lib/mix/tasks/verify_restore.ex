defmodule Mix.Tasks.VerifyRestore do
  @moduledoc """
  Checks that the database and the storage root still describe one library.

  Run this **after a restore**, before letting the application write to the
  restored volume: a non-zero exit says the two halves of the backup disagree,
  so the restore is not one you should build on yet. It is just as useful
  **before a backup**, where it answers whether the library about to be copied
  is whole — a backup of an already-inconsistent library only preserves the
  inconsistency.

  It reports and never repairs: no file is created, moved or deleted, so it is
  safe against a volume mounted read-only.

  Missing files fail the task; extra files are only listed, because the sweeper
  reclaims them. `Doctrans.Backup` explains why those two directions are not
  symmetric, and which order to take a backup in because of it.

  ## Usage

      mix verify_restore
  """

  use Mix.Task

  alias Doctrans.Backup

  @shortdoc "Check that the storage root and the database agree"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    report = Backup.verify()
    {verdict, body} = report |> Backup.lines() |> List.pop_at(-1)

    Enum.each(body, fn line -> Mix.shell().info(line) end)

    # The same verdict either way, but a failed restore has to leave a non-zero
    # exit status behind it: this task is meant to gate the boot that follows.
    if report.complete?, do: Mix.shell().info(verdict), else: Mix.raise(verdict)
  end
end
