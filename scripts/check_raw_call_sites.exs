#!/usr/bin/env elixir
# raw/1 Call Site Checker
#
# `Phoenix.HTML.raw/1` renders a string without escaping it. This app renders
# LLM-extracted content from arbitrary uploads, so every `raw/1` site is a potential
# XSS sink, and there is no Content-Security-Policy behind it: `.sobelow-conf` ignores
# `Config.CSP` because the app is loopback-bound and single-user. The sanitizer is
# therefore the only layer, which is safe exactly as long as every `raw/1` site routes
# through `MarkdownHelpers.sanitize_html/1`.
#
# That invariant is cheap to state and expensive to notice breaking, so it is pinned
# here: the set of `raw/1` call sites must match the register below. A new site fails
# this check, which forces the choice — route it through the sanitizer, or adopt CSP —
# to be made rather than defaulted into.
#
# Usage: elixir scripts/check_raw_call_sites.exs
#
# Exit code: 1 if the call sites diverge from the register, 0 otherwise

defmodule RawCallSiteChecker do
  # file => number of `raw(` call sites expected in it. Both sites below render the
  # output of MarkdownHelpers.render_markdown/2, which sanitizes before returning.
  @register %{
    "lib/doctrans_web/live/document_live/viewer_components.ex" => 1,
    "lib/doctrans_web/live/document_live/chat_components.ex" => 1
  }

  # Matches `raw(` as a call, not identifiers that merely end in "raw" (`to_raw(`).
  @call ~r/(?<![\w.])(?:Phoenix\.HTML\.)?raw\(/

  def run do
    case diff(actual_counts(), @register) do
      [] ->
        IO.puts(
          IO.ANSI.green() <>
            "raw/1 call sites match the register (#{map_size(@register)} files, " <>
            "#{@register |> Map.values() |> Enum.sum()} sites)." <> IO.ANSI.reset()
        )

        System.halt(0)

      problems ->
        IO.puts(IO.ANSI.red() <> "raw/1 call sites diverge from the register:" <> IO.ANSI.reset())
        IO.puts("")
        Enum.each(problems, &IO.puts("  " <> &1))
        IO.puts("")

        IO.puts(
          IO.ANSI.yellow() <>
            "Every raw/1 site must render sanitized HTML (MarkdownHelpers.sanitize_html/1).\n" <>
            "Confirm that, then update @register in scripts/check_raw_call_sites.exs.\n" <>
            "If raw/1 is spreading, adopt a CSP instead and drop Config.CSP from .sobelow-conf." <>
            IO.ANSI.reset()
        )

        System.halt(1)
    end
  end

  defp actual_counts do
    "lib/**/*.{ex,exs,heex}"
    |> Path.wildcard()
    |> Map.new(&{&1, count_calls(&1)})
    |> Map.reject(fn {_file, count} -> count == 0 end)
  end

  # Comment-only lines are dropped so that prose mentioning `raw(` is not a call site.
  defp count_calls(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.map(&length(Regex.scan(@call, &1)))
    |> Enum.sum()
  end

  defp diff(actual, expected) do
    Enum.flat_map(Enum.sort(Map.keys(actual) ++ Map.keys(expected)) |> Enum.uniq(), fn file ->
      case {Map.get(actual, file, 0), Map.get(expected, file, 0)} do
        {same, same} -> []
        {0, n} -> ["#{file}: registered #{n} raw/1 site(s), found none — stale register entry"]
        {n, 0} -> ["#{file}: #{n} unregistered raw/1 site(s)"]
        {n, m} -> ["#{file}: #{n} raw/1 site(s), register says #{m}"]
      end
    end)
  end
end

RawCallSiteChecker.run()
