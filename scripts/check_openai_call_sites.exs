#!/usr/bin/env elixir
# OpenAI Client Call Site Checker
#
# `Doctrans.Deps.openai/0` is the seam tests replace with `OpenAIMock`: every call
# into the OpenAI-compatible API is meant to go `Deps.openai().function(...)`, so a
# test stubs the mock and stays async. A module that names `Doctrans.Processing.OpenAI`
# directly bypasses that seam, and the tests behind it then need a real HTTP server,
# a global `:openai` env override and a fuse reset -- the coupling that produced the
# flake in #193 and the follow-up in #207.
#
# This pins the invariant: outside the register below, no file under `lib/` may alias
# `Doctrans.Processing.OpenAI` or call a function on it by its full name. Mentions in
# comments and docs are fine; the check looks for an `alias` or a call.
#
# Usage: elixir scripts/check_openai_call_sites.exs
#
# Exit code: 1 if an unregistered file names the client, 0 otherwise

defmodule OpenAICallSiteChecker do
  # Files that may name the client, and why.
  @register %{
    # The client itself.
    "lib/doctrans/processing/openai.ex" => "is the client",
    # The seam: the default the `:openai_module` env key falls back to.
    "lib/doctrans/deps.ex" => "is the seam",
    # The embedding client is a seam of its own (`Deps.embedding/0`) and delegates
    # to `OpenAI.embed/2`, which is not part of `OpenAIBehaviour`.
    "lib/doctrans/search/embedding.ex" => "implements the embedding seam"
  }

  # An `alias Doctrans.Processing.OpenAI`, bare or inside a multi-alias, or a call
  # through the full module name. `\b` keeps `OpenAIBehaviour`, `OpenAIMock` and
  # `Doctrans.Config.OpenAI` out of it.
  @patterns [
    ~r/\balias\s+Doctrans\.Processing\.OpenAI\b(?!\.)/,
    ~r/\balias\s+Doctrans\.Processing\.\{[^}]*\bOpenAI\b[^}]*\}/,
    ~r/\bDoctrans\.Processing\.OpenAI\.\w+\(/
  ]

  def run do
    case offenders() do
      [] ->
        IO.puts(
          IO.ANSI.green() <>
            "Doctrans.Processing.OpenAI is only named by the #{map_size(@register)} " <>
            "registered files; every other call goes through Deps.openai/0." <>
            IO.ANSI.reset()
        )

        System.halt(0)

      problems ->
        IO.puts(
          IO.ANSI.red() <>
            "Doctrans.Processing.OpenAI is named outside Deps.openai/0:" <> IO.ANSI.reset()
        )

        IO.puts("")
        Enum.each(problems, &IO.puts("  " <> &1))
        IO.puts("")

        IO.puts(
          IO.ANSI.yellow() <>
            "Call `Doctrans.Deps.openai().function(...)` instead, so tests can stub " <>
            "OpenAIMock\n" <>
            "and stay async. A function that is not on OpenAIBehaviour either belongs " <>
            "there, or\n" <>
            "the file belongs in @register of scripts/check_openai_call_sites.exs with " <>
            "a reason." <> IO.ANSI.reset()
        )

        System.halt(1)
    end
  end

  defp offenders do
    "lib/**/*.{ex,exs,heex}"
    |> Path.wildcard()
    |> Enum.reject(&Map.has_key?(@register, &1))
    |> Enum.flat_map(&matches/1)
  end

  # Comment-only lines are dropped so that prose naming the module is not a site.
  defp matches(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> line |> String.trim_leading() |> String.starts_with?("#") end)
    |> Enum.filter(fn {line, _n} -> Enum.any?(@patterns, &Regex.match?(&1, line)) end)
    |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
  end
end

OpenAICallSiteChecker.run()
