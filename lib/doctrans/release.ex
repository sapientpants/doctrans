defmodule Doctrans.Release do
  @moduledoc """
  Operator entrypoints for the assembled release.

  A release ships compiled BEAM files and the Erlang runtime, but no Mix and no
  sources, so `mix ecto.migrate` simply does not exist where the application
  actually runs — and neither does `mix verify_restore`, which is unfortunate in
  the one deployment whose state lives in volumes somebody has to restore. The
  scripts in `rel/overlays/bin/` reach these functions through `bin/doctrans
  eval` instead: `Ecto.Migrator.with_repo/2` starts the repository and its
  dependencies, runs the work, and stops them again, all without booting the
  endpoint — so a container can migrate, or check itself, before it serves.
  """

  alias Doctrans.{Backup, Repo}

  @app :doctrans

  @doc """
  Applies every pending migration to each configured repository.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()
    Enum.each(repos(), &run_with_repo(&1, fn repo -> migrator().run(repo, :up, all: true) end))
  end

  @doc """
  Rolls `repo` back to `version`, which stays applied; everything after it is undone.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    run_with_repo(repo, fn started -> migrator().run(started, :down, to: version) end)
  end

  @doc """
  Reports whether the database and the storage root agree, then halts.

  The same check as `mix verify_restore`, reachable where a restore actually
  happens: the runtime deployment keeps both halves of its state in named
  volumes and carries no Mix to check them with. Halts 1 when files are missing,
  so `bin/verify_restore` can gate the boot that follows it.
  """
  @spec verify_restore() :: no_return()
  def verify_restore do
    {lines, status} = restore_status()

    Enum.each(lines, &IO.puts/1)
    System.halt(status)
  end

  @doc """
  What `verify_restore/0` would print and exit with.

  Split out because `System.halt/1` ends the VM: this keeps the decision a test
  can make — which status a given restore deserves — apart from the one call
  that can only be proved by running the release, which CI does.
  """
  @spec restore_status() :: {[String.t()], 0 | 1}
  def restore_status do
    report = check()

    {Backup.lines(report), if(report.complete?, do: 0, else: 1)}
  end

  @doc """
  The same verification without the printing or the halt, for callers that want
  the report itself — `verify_restore/0` ends the VM, which a test cannot.
  """
  @spec check() :: Backup.report()
  def check do
    load_app()

    # `Ecto.Migrator.with_repo/2` is only incidentally about migrating: it starts
    # a repository and its dependencies, runs one function, and stops them again,
    # which is exactly what a check needs in a release that boots nothing else.
    # `Doctrans.Backup` queries `Doctrans.Repo`, so that is the one to start.
    {:ok, report, _apps_started} = migrator().with_repo(Repo, fn _repo -> Backup.verify() end)

    report
  end

  @doc """
  The repositories the release migrates, as configured under `:ecto_repos`.
  """
  @spec repos() :: [module()]
  def repos do
    load_app()
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp run_with_repo(repo, fun) do
    {:ok, _result, _apps_started} = migrator().with_repo(repo, fun)
    :ok
  end

  # Injectable so the suite can assert the migration plan this module issues
  # without letting a real migrator loose on the sandboxed test database, which
  # owns its connections and has every migration applied already.
  defp migrator, do: Application.get_env(@app, :migrator, Ecto.Migrator)

  # The release starts with nothing loaded; `mix test` starts with :doctrans
  # already loaded. Both outcomes are success — anything else is not.
  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end
end
