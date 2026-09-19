#!/usr/bin/env elixir
# GitHub Actions Pin Checker
#
# A `uses:` reference on a mutable tag (`@v4`) resolves to whatever commit that tag
# points at when the job runs, and anyone who can push to the action's repository can
# repoint it. The CI job already downloads and executes hook code from five external
# repositories, so the actions themselves are the part that should not also be
# mutable. A full commit SHA is the only immutable reference GitHub offers.
#
# The companion invariant is `persist-credentials: false` on every checkout: by
# default `actions/checkout` writes the job's GITHUB_TOKEN into `.git/config`, where
# any later step in the same job — including third-party action and hook code — can
# read it for the life of the job.
#
# Both are one forgotten line away from regressing, because every example in every
# action's README is written with a floating tag, so they are checked here rather
# than left to review.
#
# Usage: elixir scripts/check_action_pins.exs
#
# Exit code: 1 if any workflow violates either rule, 0 otherwise

defmodule ActionPinChecker do
  @workflows ".github/workflows/*.{yml,yaml}"

  # `uses: owner/repo[/path]@ref`, with any trailing comment captured separately. The
  # first group runs to the start of `uses:` — the column the step's other keys share —
  # so a bare `- uses:` step is measured the same as one introduced by `- name:`.
  @uses ~r/^(\s*(?:-\s+)?)uses:\s*(\S+)\s*(#.*)?$/
  @sha ~r/^[0-9a-f]{40}$/
  # A version comment is what Dependabot rewrites when it bumps a pinned SHA;
  # without one the pin is unreadable and Dependabot leaves it alone.
  @version_comment ~r/^#\s*v?\d+(\.\d+)*/

  def run do
    files = Path.wildcard(@workflows)

    if files == [] do
      abort("no workflow files matched #{@workflows}")
    end

    case Enum.flat_map(files, &check_file/1) do
      [] ->
        IO.puts(
          IO.ANSI.green() <>
            "GitHub Actions are SHA-pinned and checkouts do not persist credentials " <>
            "(#{length(files)} workflow file(s))." <> IO.ANSI.reset()
        )

        System.halt(0)

      problems ->
        IO.puts(IO.ANSI.red() <> "GitHub Actions pin check failed:" <> IO.ANSI.reset())
        IO.puts("")
        Enum.each(problems, &IO.puts("  " <> &1))
        IO.puts("")

        IO.puts(
          IO.ANSI.yellow() <>
            "Pin every action to a full commit SHA with a version comment, e.g.\n" <>
            "  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n" <>
            "Resolve a tag with:\n" <>
            "  gh api repos/OWNER/REPO/commits/TAG --jq .sha\n" <>
            "and give every actions/checkout step `persist-credentials: false`." <>
            IO.ANSI.reset()
        )

        System.halt(1)
    end
  end

  defp check_file(file) do
    lines = file |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(@uses, line) do
        [_, indent, ref | rest] -> check_uses(file, number, indent, ref, List.first(rest), lines)
        _ -> []
      end
    end)
  end

  # Local composite actions (`./.github/actions/...`) and Docker image references are
  # not tag-mutable in the same way and have no SHA form to pin to.
  defp check_uses(_file, _number, _indent, ref, _comment, _lines)
       when binary_part(ref, 0, 2) == "./",
       do: []

  defp check_uses(file, number, indent, ref, comment, lines) do
    pin_problems(file, number, ref, comment) ++
      credential_problems(file, number, indent, ref, lines)
  end

  defp pin_problems(file, number, ref, comment) do
    cond do
      String.starts_with?(ref, "docker://") ->
        []

      not String.contains?(ref, "@") ->
        [at(file, number, "`#{ref}` has no ref at all")]

      not Regex.match?(@sha, ref |> String.split("@") |> List.last()) ->
        [at(file, number, "`#{ref}` floats on a mutable tag; pin it to a full commit SHA")]

      comment == nil or not Regex.match?(@version_comment, comment) ->
        [at(file, number, "`#{ref}` is SHA-pinned but has no `# vX.Y.Z` version comment")]

      true ->
        []
    end
  end

  # A step's own keys all sit at the column where `uses:` starts, so the step ends at
  # the first line left of that column — which is the `- ` of the next list item, or
  # the dedent out of the `steps:` block.
  defp credential_problems(file, number, indent, ref, lines) do
    if checkout?(ref) and not persists_credentials_disabled?(lines, number, indent) do
      [at(file, number, "`#{ref}` does not set `persist-credentials: false`")]
    else
      []
    end
  end

  defp checkout?(ref), do: String.starts_with?(ref, "actions/checkout@")

  defp persists_credentials_disabled?(lines, number, indent) do
    depth = String.length(indent)

    lines
    |> Enum.drop(number)
    |> Enum.take_while(&within_step?(&1, depth))
    |> Enum.any?(&Regex.match?(~r/^\s*persist-credentials:\s*false\s*$/, &1))
  end

  defp within_step?(line, depth) do
    trimmed = String.trim(line)
    indent = String.length(line) - String.length(String.trim_leading(line))
    trimmed == "" or indent >= depth
  end

  defp at(file, number, message), do: "#{file}:#{number}: #{message}"

  defp abort(message) do
    IO.puts(IO.ANSI.red() <> "GitHub Actions pin check failed: #{message}" <> IO.ANSI.reset())
    System.halt(1)
  end
end

ActionPinChecker.run()
