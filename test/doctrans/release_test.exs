defmodule Doctrans.ReleaseTest do
  # `Doctrans.Release` is what a release container runs instead of `mix ecto.migrate`,
  # and nothing else in the suite exercises it. The migrator is swapped for a
  # recording stub (application env, so :async false) rather than being let loose on
  # the sandboxed test database.
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Config.Uploads
  alias Doctrans.{MigratorStub, Release, Repo, TestEnv}

  setup do
    TestEnv.put_env(:migrator, MigratorStub)
    :ok
  end

  test "repos/0 reports the repositories the release has to migrate" do
    assert Release.repos() == [Repo]
  end

  test "migrate/0 starts each repository and applies every pending migration" do
    assert Release.migrate() == :ok

    assert_received {:with_repo, Repo}
    assert_received {:run, Repo, :up, all: true}
  end

  test "restore_status/0 exits zero on a root that agrees with the database" do
    {lines, status} = Release.restore_status()

    assert status == 0
    assert List.last(lines) =~ "agree"
  end

  test "restore_status/0 exits non-zero, naming what is missing" do
    # A row whose retained original was never restored: the direction that makes
    # a restore unusable, and the one `bin/verify_restore` has to gate a boot on.
    document = document_fixture()

    {lines, status} = Release.restore_status()

    assert status == 1
    assert Enum.any?(lines, &(&1 =~ "missing: {:source_missing" and &1 =~ document.id))
  end

  test "check/0 reads the storage root through a repository it starts itself" do
    # A release boots nothing before this runs, so the check has to start the
    # repository it queries; `verify_restore/0` only adds the printing and the
    # halt that a test cannot survive.
    report = Release.check()

    assert_received {:with_repo, Repo}
    assert report.root == Uploads.upload_dir()
    assert report.complete?
  end

  test "rollback/2 undoes everything applied after the given version" do
    assert Release.rollback(Repo, 20_250_101_000_000) == :ok

    assert_received {:with_repo, Repo}
    assert_received {:run, Repo, :down, to: 20_250_101_000_000}
  end
end
