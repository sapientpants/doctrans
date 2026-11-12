#!/usr/bin/env elixir
# Pre-commit Pin Checker
# Every external hook repository in `.pre-commit-config.yaml` is cloned and, for the
# Python and Node hooks, installed and executed on the developer's machine the first
# time a (repo, rev) pair is seen. A `rev:` that names a tag can be repointed by
# anyone who can push to that repository, and the next cold cache -- a new machine,
# `pre-commit clean`, a CI cache miss -- runs whatever it now points at. So each
# `rev:` must be a full commit SHA, with the human-readable tag kept in the
# `# frozen: <tag>` comment that `pre-commit autoupdate --freeze` writes. The header
# of `.pre-commit-config.yaml` has the policy; this catches the regression, which is
# one `autoupdate` without `--freeze` away.
#
# The `pre-commit` tool itself is installed in CI from a hashed requirements file,
# so this also requires every `pip install` in the workflows to pass
# `--require-hashes`: a bare `pip install pre-commit` takes whatever PyPI serves.
#
# Usage: elixir scripts/check_precommit_pins.exs
#
# Exit code: 1 if any remote hook rev is not a frozen commit SHA, or any workflow
# pip install is unhashed, 0 otherwise

defmodule PrecommitPinChecker do
  @config ".pre-commit-config.yaml"
  @workflows_dir ".github/workflows"
  @builtin_repos ["local", "meta"]

  def run do
    repos = remote_repos!()
    problems = Enum.flat_map(repos, &check_repo/1) ++ check_workflows()

    case problems do
      [] ->
        IO.puts(
          IO.ANSI.green() <>
            "Pre-commit pins are frozen (#{length(repos)} remote hook repositories pinned " <>
            "to commit SHAs; every workflow pip install requires hashes)." <>
            IO.ANSI.reset()
        )

        System.halt(0)

      problems ->
        IO.puts(IO.ANSI.red() <> "Pre-commit pin check failed:" <> IO.ANSI.reset())
        IO.puts("")
        Enum.each(problems, &IO.puts("  " <> &1))
        IO.puts("")

        IO.puts(
          IO.ANSI.yellow() <>
            "Freeze a hook with `pre-commit autoupdate --freeze --repo <url>`, which writes " <>
            "the commit SHA and a `# frozen: <tag>` comment; never run `autoupdate` without " <>
            "`--freeze`. Install pre-commit in CI from .github/requirements-pre-commit.txt." <>
            IO.ANSI.reset()
        )

        System.halt(1)
    end
  end

  # Each `- repo: <url>` entry with the `rev:` line that follows it (if any), in file
  # order. `local` and `meta` repositories have no rev and are skipped. Parsed line by
  # line rather than as YAML so the script stays dependency-free, the same way the
  # other gates read their inputs.
  defp remote_repos! do
    lines = @config |> read_file!() |> String.split("\n")

    {repos, _current} =
      Enum.reduce(lines, {[], nil}, fn line, {repos, current} ->
        repo = Regex.run(~r/^\s*-\s*repo:\s*(\S+)\s*$/, line)
        rev = Regex.run(~r/^\s*rev:\s*(.*?)\s*$/, line)

        case {repo, rev, repos} do
          {[_, url], _, _} ->
            {[%{url: url, rev: nil} | repos], url}

          {nil, [_, rev], [head | rest]} when current != nil ->
            {[%{head | rev: rev} | rest], current}

          _ ->
            {repos, current}
        end
      end)

    repos = repos |> Enum.reverse() |> Enum.reject(&(&1.url in @builtin_repos))

    if repos == [], do: abort("no remote hook repositories found in #{@config}")

    repos
  end

  defp check_repo(%{url: url, rev: nil}) do
    ["#{url} has no `rev:` line"]
  end

  # The rev value may be bare or quoted (`rev: "sha"` is valid YAML that pre-commit
  # accepts); the trailing `# ...` comment, if any, is checked separately.
  defp check_repo(%{url: url, rev: rev}) do
    {value, comment} = split_rev(rev)

    cond do
      not Regex.match?(~r/^[0-9a-fA-F]+$/, value) ->
        ["#{url} pins `#{value}` by tag; freeze it to a commit SHA"]

      byte_size(value) != 40 ->
        ["#{url} pins `#{value}`, which is not a full 40-hex commit SHA"]

      not Regex.match?(~r/^#\s*frozen:\s*\S+/, comment) ->
        ["#{url} pins `#{value}` without a `# frozen: <tag>` comment naming the version"]

      true ->
        []
    end
  end

  defp split_rev(rev) do
    case Regex.run(~r/^("[^"]*"|'[^']*'|[^\s#]*)\s*(#.*)?$/, rev) do
      [_, value] -> {unquote_rev(value), ""}
      [_, value, comment] -> {unquote_rev(value), comment}
      nil -> {rev, ""}
    end
  end

  defp unquote_rev(value), do: value |> String.trim("\"") |> String.trim("'")

  # Every `pip install` in a workflow must pass `--require-hashes`, so the installed
  # tool and its transitive dependencies are the ones the requirements file names.
  defp check_workflows do
    @workflows_dir
    |> workflow_files()
    |> Enum.flat_map(fn path ->
      path
      |> read_file!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim_leading(line), "#") end)
      |> Enum.filter(fn {line, _} -> line =~ ~r/\bpip3?\s+install\b/ end)
      |> Enum.reject(fn {line, _} -> line =~ "--require-hashes" end)
      |> Enum.map(fn {_, number} ->
        "#{path}:#{number} runs `pip install` without `--require-hashes`"
      end)
    end)
  end

  defp workflow_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, [".yml", ".yaml"]))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp read_file!(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> abort("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp abort(message) do
    IO.puts(IO.ANSI.red() <> "Pre-commit pin check failed: #{message}" <> IO.ANSI.reset())
    System.halt(1)
  end
end

PrecommitPinChecker.run()
