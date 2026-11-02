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

  # An `alias Doctrans.Processing.OpenAI`, bare or inside a multi-alias (which the
  # formatter may spread over several lines), a call through the full module name
  # or through a bare `alias Doctrans.Processing`, or a function capture of either.
  # `\b` keeps `OpenAIBehaviour`, `OpenAIMock` and `Doctrans.Config.OpenAI` out of
  # it; requiring `(` or a leading `&` keeps `Doctrans.Processing.OpenAI.embed/2`
  # in a `@moduledoc` out of it.
  @patterns [
    ~r/\balias\s+Doctrans\.Processing\.OpenAI\b(?!\.)/,
    ~r/\balias\s+Doctrans\.Processing\.\{[^}]*\bOpenAI\b[^}]*\}/,
    ~r/\b(?:Doctrans\.)?Processing\.OpenAI\.\w+\(/,
    ~r/&(?:Doctrans\.)?Processing\.OpenAI\.\w+\/\d+/
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

  # Comment-only lines are blanked (not dropped, so line numbers hold) so that
  # prose naming the module is not a site. The patterns then run over the whole
  # file, so an alias block spread across lines is still one match.
  defp matches(file) do
    text =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if line |> String.trim_leading() |> String.starts_with?("#"), do: "", else: line
      end)

    @patterns
    |> Enum.flat_map(&Regex.scan(&1, text, return: :index))
    |> Enum.map(fn [{start, length} | _] -> {start, length} end)
    |> Enum.sort()
    |> Enum.uniq_by(fn {start, _length} -> line_number(text, start) end)
    |> Enum.map(fn {start, length} ->
      site = text |> binary_part(start, length) |> String.replace(~r/\s+/, " ")
      "#{file}:#{line_number(text, start)}: #{site}"
    end)
  end

  defp line_number(text, offset) do
    length(:binary.matches(binary_part(text, 0, offset), "\n")) + 1
  end
end

OpenAICallSiteChecker.run()
