defmodule Scripts.CheckPrecommitPinsTest do
  @moduledoc """
  Smoke-tests the pre-commit gate in `scripts/check_precommit_pins.exs`.

  Every remote hook repository must pin a full commit SHA with the tag kept in a
  `# frozen:` comment, and every workflow `pip install` must require hashes. Each
  case starts from a passing tree, breaks one thing, and checks that the gate
  names it.
  """
  use ExUnit.Case, async: true

  import Doctrans.GateScript, only: [run: 3, write: 3]

  @moduletag :tmp_dir
  @script "check_precommit_pins.exs"

  @sha String.duplicate("ab", 20)
  @hooks_repo "https://github.com/pre-commit/pre-commit-hooks"
  @yamllint_repo "https://github.com/adrienverge/yamllint"

  @config """
  repos:
    - repo: #{@hooks_repo}
      rev: #{@sha}  # frozen: v6.0.0
      hooks:
        - id: trailing-whitespace
    - repo: #{@yamllint_repo}
      rev: #{@sha}  # frozen: v1.38.0
      hooks:
        - id: yamllint
    - repo: local
      hooks:
        - id: mix-format
          entry: mix format --check-formatted
          language: system
  """

  @workflow """
  jobs:
    verify:
      steps:
        # Not `pip install pre-commit`: a comment is not an install.
        - name: Install pre-commit
          run: pip install --require-hashes -r .github/requirements-pre-commit.txt
  """

  setup %{tmp_dir: dir} do
    write(dir, ".pre-commit-config.yaml", @config)
    write(dir, ".github/workflows/ci.yml", @workflow)
    :ok
  end

  test "frozen SHAs and a hashed pip install pass", %{tmp_dir: dir} do
    assert {output, 0} = run(@script, [], dir)
    assert output =~ "Pre-commit pins are frozen (2 remote hook repositories"
  end

  test "a rev that is a tag fails, naming the repository", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      String.replace(@config, "#{@sha}  # frozen: v1.38.0", "v1.38.0")
    )

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{@yamllint_repo} pins `v1.38.0` by tag"
    refute output =~ "#{@hooks_repo} pins"
  end

  test "a quoted frozen SHA passes", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      String.replace(
        @config,
        "rev: #{@sha}  # frozen: v6.0.0",
        "rev: \"#{@sha}\"  # frozen: v6.0.0"
      )
    )

    assert {_output, 0} = run(@script, [], dir)
  end

  test "a quoted tag fails, naming the tag without its quotes", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      String.replace(@config, "#{@sha}  # frozen: v1.38.0", "'v1.38.0'")
    )

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{@yamllint_repo} pins `v1.38.0` by tag"
  end

  test "a SHA without a frozen comment fails", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      String.replace(@config, "#{@sha}  # frozen: v6.0.0", @sha)
    )

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{@hooks_repo} pins `#{@sha}` without a `# frozen: <tag>` comment"
  end

  test "an abbreviated SHA fails", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      String.replace(@config, "#{@sha}  # frozen: v6.0.0", "abababab  # frozen: v6.0.0")
    )

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{@hooks_repo} pins `abababab`, which is not a full 40-hex commit SHA"
  end

  test "a remote repository with no rev fails", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      String.replace(@config, "    rev: #{@sha}  # frozen: v1.38.0\n", "")
    )

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "#{@yamllint_repo} has no `rev:` line"
  end

  test "local and meta repositories need no rev", %{tmp_dir: dir} do
    write(
      dir,
      ".pre-commit-config.yaml",
      @config <> "  - repo: meta\n    hooks:\n      - id: check-hooks-apply\n"
    )

    assert {_output, 0} = run(@script, [], dir)
  end

  test "a config with only local repositories aborts rather than passing in silence",
       %{tmp_dir: dir} do
    write(dir, ".pre-commit-config.yaml", "repos:\n  - repo: local\n    hooks: []\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "no remote hook repositories found in .pre-commit-config.yaml"
  end

  test "a workflow pip install without --require-hashes fails with its line number",
       %{tmp_dir: dir} do
    write(
      dir,
      ".github/workflows/ci.yml",
      String.replace(
        @workflow,
        "pip install --require-hashes -r .github/requirements-pre-commit.txt",
        "pip install pre-commit"
      )
    )

    assert {output, 1} = run(@script, [], dir)
    assert output =~ ".github/workflows/ci.yml:6 runs `pip install` without `--require-hashes`"
  end

  test "a missing config aborts", %{tmp_dir: dir} do
    File.rm!(Path.join(dir, ".pre-commit-config.yaml"))

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "cannot read .pre-commit-config.yaml"
  end
end
