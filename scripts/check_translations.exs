#!/usr/bin/env elixir
# Translation Checker
# Ensures every translation key has a translation for each supported language,
# that none of them is still flagged `fuzzy`, and that each one interpolates the
# same `%{bindings}` as the msgid it translates.
#
# A fuzzy entry is one `mix gettext.extract --merge` auto-filled from a *different*
# msgid it found similar. Elixir's Gettext renders those at runtime, so a fuzzy
# entry is not a placeholder -- it is wrong text already shipping. That is not
# hypothetical here: the upload dialog read "Drag and drop PDF files here, or"
# from a msgid that says "documents", the German and French language pickers
# listed Spanish where Danish belongs, and a sort control announced itself to
# screen readers as "Search documents". All of them passed the completeness check
# before this one existed, because a non-empty msgstr is all it looked for.
#
# Parsing goes through `Expo.PO`, the parser Gettext itself uses, rather than a
# hand-rolled line reader. A line reader has to special-case what Expo already
# models: wrapped msgids (`msgid ""` followed by continuation strings, which a
# naive reader cannot tell from the header entry), obsolete `#~` blocks, plural
# forms, and `msgctxt`. Getting any of those wrong makes the gate pass a file it
# should reject, which is the one failure mode a gate must not have.
#
# The binding check exists because Gettext does not enforce it. Its default
# `handle_missing_bindings/2` logs an error and renders the string as written --
# it does not raise -- so a msgstr that drops `%{host}` from "Documents are sent
# to %{host} for processing" ships a privacy disclosure with the destination
# silently gone, in one language, with every test green. A msgstr that renames a
# binding renders the placeholder literally instead.
#
# Usage: mix run --no-start scripts/check_translations.exs [--path PATH]
#
# Default path: priv/gettext
# Exit code: 1 if any translation is missing, fuzzy, or has mismatched bindings

defmodule TranslationChecker do
  @default_path "priv/gettext"
  # Source language uses msgid as translation, so empty msgstr is acceptable
  @source_language "en"
  # Gettext's interpolation syntax, the only thing a msgstr must reproduce exactly.
  @binding ~r/%\{([a-zA-Z0-9_]+)\}/

  def run(args) do
    {opts, _} = parse_args(args)
    gettext_path = Keyword.get(opts, :path, @default_path)

    if not File.dir?(gettext_path) do
      abort("Gettext directory not found: #{gettext_path}")
    end

    result = check(gettext_path)

    report(
      result.missing,
      result.fuzzy,
      result.bindings,
      result.problems,
      result.language_dirs,
      result.fuzzy_langs
    )
  end

  @doc """
  Collects every issue under `gettext_path` without printing or exiting.

  `run/1` is the script entry point; this is the seam the test suite drives.
  """
  def check(gettext_path) do
    pot_files = Path.wildcard(Path.join(gettext_path, "*.pot"))
    language_dirs = language_dirs(gettext_path)

    # The source language is exempt from the completeness check -- an empty msgstr
    # there falls back to the msgid -- but not from the fuzzy check: a fuzzy entry
    # in `en` renders the borrowed string instead of the msgid.
    fuzzy_langs = Enum.filter([@source_language | language_dirs], &locale_dir?(gettext_path, &1))

    # The fuzzy scan needs neither a POT file nor a translated language, so it runs
    # ahead of the configuration guards below. Ordering it after them would let a
    # fuzzy `en` entry through with a green exit in a tree that has no other locale.
    fuzzy_issues = check_fuzzy(gettext_path, fuzzy_langs)
    binding_issues = check_bindings(gettext_path, fuzzy_langs)
    missing_issues = check_missing(gettext_path, pot_files, language_dirs)

    # An empty tree means the gate looked somewhere it should not have -- a moved
    # directory, a bad --path, a deleted .pot. Passing on it would report success
    # for having checked nothing, so it fails instead.
    problems =
      [
        {pot_files == [], "No POT files found in #{gettext_path}"},
        {language_dirs == [], "No language directories found in #{gettext_path}"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      missing: missing_issues,
      fuzzy: fuzzy_issues,
      bindings: binding_issues,
      problems: problems,
      language_dirs: language_dirs,
      fuzzy_langs: fuzzy_langs
    }
  end

  defp report([], [], [], [], language_dirs, fuzzy_langs) do
    IO.puts(
      IO.ANSI.green() <>
        "All translations are complete for #{length(language_dirs)} languages, and none of " <>
        "the #{length(fuzzy_langs)} locales scanned is fuzzy or drops an interpolation." <>
        IO.ANSI.reset()
    )

    System.halt(0)
  end

  defp report(missing, fuzzy, bindings, problems, _language_dirs, _fuzzy_langs) do
    Enum.each(problems, &IO.puts(IO.ANSI.red() <> &1 <> IO.ANSI.reset()))
    report_missing(missing)
    report_fuzzy(fuzzy)
    report_bindings(bindings)
    System.halt(1)
  end

  defp report_bindings([]), do: :ok

  defp report_bindings(issues) do
    IO.puts(IO.ANSI.red() <> "Interpolation mismatches found:" <> IO.ANSI.reset())
    IO.puts("")
    print_grouped(issues)

    IO.puts(
      IO.ANSI.yellow() <>
        "Total: #{length(issues)} translation(s) whose bindings do not match their msgid. " <>
        "Gettext logs and renders these rather than raising, so a dropped binding is a " <>
        "sentence shipping with the value missing. Restore the placeholder in the msgstr." <>
        IO.ANSI.reset()
    )
  end

  defp report_fuzzy([]), do: :ok

  defp report_fuzzy(issues) do
    IO.puts(IO.ANSI.red() <> "Fuzzy translations found:" <> IO.ANSI.reset())
    IO.puts("")
    print_grouped(issues)

    IO.puts(
      IO.ANSI.yellow() <>
        "Total: #{length(issues)} fuzzy translation(s). Gettext renders these, so each one is " <>
        "wrong text already shipping. Correct the msgstr, then delete `fuzzy` from its `#,` line." <>
        IO.ANSI.reset()
    )
  end

  defp report_missing([]), do: :ok

  defp report_missing(issues) do
    IO.puts(IO.ANSI.red() <> "Missing translations found:" <> IO.ANSI.reset())
    IO.puts("")
    print_grouped(issues)

    IO.puts(
      IO.ANSI.yellow() <>
        "Total: #{length(issues)} missing translation(s). " <>
        "Run 'mix gettext.merge priv/gettext' to add missing entries." <>
        IO.ANSI.reset()
    )
  end

  defp print_grouped(issues) do
    issues
    |> Enum.group_by(fn {lang, _domain, _msgid} -> lang end)
    |> Enum.sort()
    |> Enum.each(fn {lang, lang_issues} ->
      IO.puts("  #{IO.ANSI.cyan()}#{lang}#{IO.ANSI.reset()} (#{length(lang_issues)}):")

      lang_issues
      |> Enum.group_by(fn {_lang, domain, _msgid} -> domain end)
      |> Enum.sort()
      |> Enum.each(fn {domain, domain_issues} ->
        IO.puts("    #{domain}:")

        Enum.each(domain_issues, fn {_lang, _domain, msgid} ->
          IO.puts("      - #{inspect(truncate(msgid, 60))}")
        end)
      end)

      IO.puts("")
    end)
  end

  defp check_fuzzy(gettext_path, langs) do
    for lang <- langs,
        po_file <- po_files(gettext_path, lang),
        message <- live_messages(po_file),
        Expo.Message.has_flag?(message, "fuzzy") do
      {lang, Path.basename(po_file, ".po"), label(message)}
    end
  end

  # Bindings are compared per form: `msgstr[0]` against the msgid, every higher
  # form against msgid_plural, matching how Gettext picks the string to render.
  defp check_bindings(gettext_path, langs) do
    for lang <- langs,
        po_file <- po_files(gettext_path, lang),
        message <- live_messages(po_file),
        issue <- binding_issues(message) do
      {lang, Path.basename(po_file, ".po"), "#{label(message)} -- #{issue}"}
    end
  end

  defp binding_issues(%Expo.Message.Singular{msgid: msgid, msgstr: msgstr}) do
    compare_bindings(msgid, msgstr, "msgstr")
  end

  defp binding_issues(%Expo.Message.Plural{} = message) do
    Enum.flat_map(message.msgstr, fn {form, translation} ->
      source = if form == 0, do: message.msgid, else: message.msgid_plural
      compare_bindings(source, translation, "msgstr[#{form}]")
    end)
  end

  # An empty msgstr falls back to the msgid and so carries the right bindings by
  # construction; reporting it here would just duplicate `check_missing/3`, and
  # would fail the source language, where empty is the expected state.
  defp compare_bindings(source, translation, form) do
    if blank?(translation) do
      []
    else
      expected = bindings(source)
      actual = bindings(translation)

      describe_bindings(form, MapSet.difference(expected, actual), "drops") ++
        describe_bindings(form, MapSet.difference(actual, expected), "adds unknown")
    end
  end

  defp describe_bindings(form, diff, verb) do
    if Enum.empty?(diff) do
      []
    else
      ["#{form} #{verb} #{Enum.map_join(Enum.sort(diff), ", ", &"%{#{&1}}")}"]
    end
  end

  defp bindings(segments) do
    @binding
    |> Regex.scan(Enum.join(segments), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp check_missing(gettext_path, pot_files, language_dirs) do
    for pot_file <- pot_files, lang <- language_dirs do
      domain = Path.basename(pot_file, ".pot")
      po_file = Path.join([gettext_path, lang, "LC_MESSAGES", "#{domain}.po"])
      translated = translated_keys(po_file)

      pot_file
      |> live_messages()
      |> Enum.reject(&MapSet.member?(translated, Expo.Message.key(&1)))
      |> Enum.map(&{lang, domain, label(&1)})
    end
    |> List.flatten()
  end

  defp translated_keys(po_file) do
    po_file
    |> live_messages()
    |> Enum.reject(&untranslated?/1)
    |> MapSet.new(&Expo.Message.key/1)
  end

  # Gettext falls back to the msgid when a msgstr is empty, so an empty one ships
  # the source string. For a plural, it does that per form -- a translated
  # singular does not cover an empty `msgstr[1]`, so every form has to be filled.
  defp untranslated?(%Expo.Message.Singular{msgstr: msgstr}), do: blank?(msgstr)

  defp untranslated?(%Expo.Message.Plural{msgstr: msgstr}),
    do: msgstr |> Map.values() |> Enum.any?(&blank?/1)

  defp blank?(segments), do: segments |> Enum.join() |> String.trim() == ""

  # Obsolete `#~` entries are not rendered, so they can neither satisfy the
  # completeness check nor fail the fuzzy one.
  defp live_messages(file) do
    case Expo.PO.parse_file(file) do
      {:ok, po} ->
        Enum.reject(po.messages, & &1.obsolete)

      # A PO file that does not exist yet is every entry missing, not an error.
      {:error, :enoent} ->
        []

      {:error, %Expo.PO.SyntaxError{line: line, reason: reason}} ->
        abort("#{file}:#{line}: #{reason}")

      {:error, reason} ->
        abort("Could not read #{file}: #{:file.format_error(reason)}")
    end
  end

  defp label(%{msgid: msgid, msgctxt: nil}), do: Enum.join(msgid)
  defp label(%{msgid: msgid, msgctxt: msgctxt}), do: "#{Enum.join(msgctxt)} | #{Enum.join(msgid)}"

  defp po_files(gettext_path, lang) do
    Path.wildcard(Path.join([gettext_path, lang, "LC_MESSAGES", "*.po"]))
  end

  defp locale_dir?(gettext_path, lang), do: File.dir?(Path.join(gettext_path, lang))

  defp language_dirs(gettext_path) do
    gettext_path
    |> File.ls!()
    |> Enum.filter(fn name ->
      locale_dir?(gettext_path, name) and name != @source_language
    end)
    |> Enum.sort()
  end

  defp abort(message) do
    IO.puts(IO.ANSI.red() <> message <> IO.ANSI.reset())
    System.halt(1)
  end

  defp parse_args(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [path: :string, help: :boolean],
        aliases: [p: :path, h: :help]
      )

    if opts[:help] do
      IO.puts("""
      Translation Checker

      Verifies that every msgid in a .pot template has a non-empty translation in
      every language, and that no entry in any locale -- including the source
      language -- is still flagged `fuzzy`.

      Usage: mix run --no-start scripts/check_translations.exs [options]

      Options:
        -p, --path PATH    Path to gettext directory (default: #{@default_path})
        -h, --help         Show this help message

      Examples:
        mix run --no-start scripts/check_translations.exs
        mix run --no-start scripts/check_translations.exs --path priv/gettext
      """)

      System.halt(0)
    end

    {opts, rest}
  end

  defp truncate(string, max_length) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length - 3) <> "..."
    else
      string
    end
  end
end

# Guarded so the test suite can require this file for the module alone. Every
# other entry point (`mix run`, `elixir`) runs in a non-test env and checks.
if not (Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test) do
  TranslationChecker.run(System.argv())
end
