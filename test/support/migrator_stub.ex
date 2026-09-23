defmodule Doctrans.MigratorStub do
  @moduledoc """
  An `Ecto.Migrator` that records what it was asked to do instead of doing it.

  `Doctrans.Release` exists to run migrations where there is no Mix, so the thing
  worth asserting is the plan it issues — which repository, which direction, which
  options. Running a real migrator from the suite is not an option: the test
  database has every migration applied already, and `Ecto.Migrator.with_repo/2`
  would start a second repository outside the sandbox's ownership, checking out a
  connection the sandbox has not granted.

  `Doctrans.Release` runs in-line in the calling process, so each call lands in
  that process's own mailbox and the test reads it back with `assert_received`.
  """

  @doc """
  Stands in for `Ecto.Migrator.with_repo/2`: records the repository and invokes
  `fun` with it, as the real one does once the repository is started.
  """
  def with_repo(repo, fun) do
    send(self(), {:with_repo, repo})
    {:ok, fun.(repo), []}
  end

  @doc "Stands in for `Ecto.Migrator.run/3`, recording the direction and options."
  def run(repo, direction, opts) do
    send(self(), {:run, repo, direction, opts})
    []
  end
end
