defmodule Doctrans.Jobs.RunCleanupJobTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents.Layout
  alias Doctrans.Jobs.{Keys, RunCleanupJob}

  import Doctrans.Fixtures

  # `Ecto.UUID.cast/1` accepts both of these, so a check built on it would take
  # them for stale run directories (#313). The layout never writes either.
  @foreign_names ["abcdefghijklmnop", String.upcase(Uniq.UUID.uuid7())]

  test "removes stale run directories and leaves entries the layout never writes" do
    document = document_fixture()
    runs = Layout.runs_dir(document.id)
    on_exit(fn -> File.rm_rf!(Layout.document_dir(document.id)) end)

    stale = Path.join(runs, Uniq.UUID.uuid7())
    foreign = Enum.map(@foreign_names, &Path.join(runs, &1))
    for dir <- [stale | foreign], do: File.mkdir_p!(dir)

    assert :ok = RunCleanupJob.perform(%Oban.Job{args: %{Keys.document_id() => document.id}})

    refute File.exists?(stale)
    assert Enum.all?(foreign, &File.dir?/1)
  end
end
