#!/usr/bin/env elixir
# Translation Completeness Checker
# Ensures all translation keys have translations for each supported language.
#
# Usage: elixir scripts/check_translations.exs [--path PATH]
#
# Default path: priv/gettext
# Exit code: 1 if any translations are missing, 0 otherwise

defmodule TranslationChecker do
  @default_path "priv/gettext"
  # Source language uses msgid as translation, so empty msgstr is acceptable
  @source_language "en"

  def run(args) do
    {opts, _} = parse_args(args)
    gettext_path = Keyword.get(opts, :path, @default_path)

    # Find all POT files (templates)
    pot_files = Path.wildcard(Path.join(gettext_path, "*.pot"))

    if pot_files == [] do
      IO.puts(IO.ANSI.yellow() <> "No POT files found in #{gettext_path}" <> IO.ANSI.reset())
      System.halt(0)
    end

    # Find all language directories (exclude source language - it uses msgid as translation)
    language_dirs =
      gettext_path
      |> File.ls!()
      |> Enum.filter(fn name ->
        Path.join(gettext_path, name) |> File.dir?() and
          name != "." and name != ".." and name != @source_language
      end)
      |> Enum.sort()

    if language_dirs == [] do
      IO.puts(IO.ANSI.yellow() <> "No language directories found in #{gettext_path}" <> IO.ANSI.reset())
      System.halt(0)
    end

    # Check each POT file against each language
    all_issues =
      for pot_file <- pot_files,
          lang <- language_dirs do
        check_language(pot_file, gettext_path, lang)
      end
      |> List.flatten()

    case all_issues do
      [] ->
        IO.puts(IO.ANSI.green() <> "All translations are complete for #{length(language_dirs)} languages." <> IO.ANSI.reset())
        System.halt(0)

      issues ->
        IO.puts(IO.ANSI.red() <> "Missing translations found:" <> IO.ANSI.reset())
        IO.puts("")

        issues
        |> Enum.group_by(fn {lang, _domain, _msgid} -> lang end)
        |> Enum.sort()
        |> Enum.each(fn {lang, lang_issues} ->
          IO.puts("  #{IO.ANSI.cyan()}#{lang}#{IO.ANSI.reset()} (#{length(lang_issues)} missing):")

          lang_issues
          |> Enum.group_by(fn {_lang, domain, _msgid} -> domain end)
          |> Enum.sort()
          |> Enum.each(fn {domain, domain_issues} ->
            IO.puts("    #{domain}:")
            Enum.each(domain_issues, fn {_lang, _domain, msgid} ->
              truncated = truncate(msgid, 60)
              IO.puts("      - #{inspect(truncated)}")
            end)
          end)

          IO.puts("")
        end)

        total = length(issues)
        IO.puts(IO.ANSI.yellow() <>
          "Total: #{total} missing translation(s). Run 'mix gettext.merge priv/gettext' to add missing entries." <>
          IO.ANSI.reset())

        System.halt(1)
    end
  end

  defp parse_args(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [path: :string, help: :boolean],
        aliases: [p: :path, h: :help]
      )

    if opts[:help] do
      IO.puts("""
      Translation Completeness Checker

      Usage: elixir scripts/check_translations.exs [options]

      Options:
        -p, --path PATH    Path to gettext directory (default: #{@default_path})
        -h, --help         Show this help message

      Examples:
        elixir scripts/check_translations.exs
        elixir scripts/check_translations.exs --path priv/gettext
      """)

      System.halt(0)
    end

    {opts, rest}
  end

  defp check_language(pot_file, gettext_path, lang) do
    domain = Path.basename(pot_file, ".pot")
    po_file = Path.join([gettext_path, lang, "LC_MESSAGES", "#{domain}.po"])

    if File.exists?(po_file) do
      pot_entries = parse_po_file(pot_file)
      po_entries = parse_po_file(po_file)

      # Find msgids that exist in POT but have empty msgstr in PO
      pot_entries
      |> Enum.filter(fn {msgid, _} -> msgid != "" end)
      |> Enum.filter(fn {msgid, _is_plural} ->
        case Map.get(po_entries, msgid) do
          nil ->
            # msgid doesn't exist in PO file
            true

          {_is_plural, translations} ->
            # Check if all translations are empty
            Enum.all?(translations, fn {_key, value} -> value == "" end)
        end
      end)
      |> Enum.map(fn {msgid, _is_plural} -> {lang, domain, msgid} end)
    else
      # PO file doesn't exist - report all POT entries as missing
      pot_entries = parse_po_file(pot_file)

      pot_entries
      |> Enum.filter(fn {msgid, _} -> msgid != "" end)
      |> Enum.map(fn {msgid, _is_plural} -> {lang, domain, msgid} end)
    end
  end

  defp parse_po_file(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> parse_entries(%{}, nil, nil, false, %{})
  end

  # Parse PO/POT file format
  # Returns a map of msgid => {is_plural, %{key => translation}}
  defp parse_entries([], acc, current_msgid, _current_msgid_plural, is_plural, translations) do
    if current_msgid do
      Map.put(acc, current_msgid, {is_plural, translations})
    else
      acc
    end
  end

  defp parse_entries([line | rest], acc, current_msgid, current_msgid_plural, is_plural, translations) do
    line = String.trim(line)

    cond do
      # Skip comments and empty lines
      String.starts_with?(line, "#") or line == "" ->
        parse_entries(rest, acc, current_msgid, current_msgid_plural, is_plural, translations)

      # New msgid
      String.starts_with?(line, "msgid ") ->
        # Save previous entry if exists
        acc =
          if current_msgid do
            Map.put(acc, current_msgid, {is_plural, translations})
          else
            acc
          end

        msgid = extract_string(line, "msgid ")
        parse_entries(rest, acc, msgid, nil, false, %{})

      # Plural msgid
      String.starts_with?(line, "msgid_plural ") ->
        msgid_plural = extract_string(line, "msgid_plural ")
        parse_entries(rest, acc, current_msgid, msgid_plural, true, translations)

      # Regular msgstr
      String.starts_with?(line, "msgstr ") ->
        msgstr = extract_string(line, "msgstr ")
        translations = Map.put(translations, :singular, msgstr)
        parse_entries(rest, acc, current_msgid, current_msgid_plural, is_plural, translations)

      # Plural msgstr[N]
      Regex.match?(~r/^msgstr\[\d+\]/, line) ->
        [_, index, value] = Regex.run(~r/^msgstr\[(\d+)\]\s*(.*)$/, line)
        msgstr = extract_quoted_string(value)
        translations = Map.put(translations, String.to_integer(index), msgstr)
        parse_entries(rest, acc, current_msgid, current_msgid_plural, true, translations)

      # Continuation of previous string (starts with ")
      String.starts_with?(line, "\"") ->
        # This is a continuation line, append to the appropriate field
        continuation = extract_quoted_string(line)

        translations =
          cond do
            Map.has_key?(translations, :singular) ->
              Map.update!(translations, :singular, &(&1 <> continuation))

            true ->
              # Find the last numeric key and append to it
              last_key =
                translations
                |> Map.keys()
                |> Enum.filter(&is_integer/1)
                |> Enum.max(fn -> nil end)

              if last_key do
                Map.update!(translations, last_key, &(&1 <> continuation))
              else
                translations
              end
          end

        parse_entries(rest, acc, current_msgid, current_msgid_plural, is_plural, translations)

      true ->
        parse_entries(rest, acc, current_msgid, current_msgid_plural, is_plural, translations)
    end
  end

  defp extract_string(line, prefix) do
    line
    |> String.trim_leading(prefix)
    |> extract_quoted_string()
  end

  defp extract_quoted_string(str) do
    str = String.trim(str)

    if String.starts_with?(str, "\"") and String.ends_with?(str, "\"") do
      str
      |> String.slice(1..-2//1)
      |> unescape_string()
    else
      ""
    end
  end

  defp unescape_string(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp truncate(string, max_length) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length - 3) <> "..."
    else
      string
    end
  end
end

TranslationChecker.run(System.argv())
