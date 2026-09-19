#!/usr/bin/env elixir
# Dialyzer Suppression Register Checker
# `.dialyzer_ignore.exs` is a register, not a dumping ground: every filter names one
# line of one file, and carries an owner, an expiry, an upstream link, and a rationale.
# `--list-unused-filters` retires a filter once the code moves, but it cannot see an
# over-broad filter or a stale justification — this check covers both, and fails the
# gate when an entry outlives its expiry date.
#
# Usage: elixir scripts/check_dialyzer_filters.exs [--today YYYY-MM-DD]
#
# Exit code: 1 if the register is malformed, over cap, or holds an expired entry

defmodule DialyzerFilterChecker do
  @register ".dialyzer_ignore.exs"
  @max_entries 8
  @required_keys ["owner", "expires", "upstream", "rationale"]

  def run(args) do
    today = parse_today(args)
    entries = parse_entries(read_file!(@register))
    tuples = eval_register!()

    case problems(entries, tuples, today) do
      [] ->
        report_ok(entries, today)

      problems ->
        report_problems(problems)
    end
  end

  defp problems(entries, tuples, today) do
    cap_problems(entries) ++
      pairing_problems(entries, tuples) ++
      entry_problems(entries, tuples, today)
  end

  defp cap_problems(entries) when length(entries) > @max_entries do
    [
      {nil,
       "register holds #{length(entries)} entries, cap is #{@max_entries} — " <>
         "raise the cap in this script deliberately, or retire an entry"}
    ]
  end

  defp cap_problems(_entries), do: []

  # The text scan and the evaluated list must see the same entries; a mismatch means an
  # entry spans several lines, which would let it slip past the metadata check.
  defp pairing_problems(entries, tuples) when length(entries) != length(tuples) do
    [
      {nil,
       "found #{length(entries)} entry lines but #{length(tuples)} filters — " <>
         "keep each filter on a single line"}
    ]
  end

  defp pairing_problems(_entries, _tuples), do: []

  defp entry_problems(entries, tuples, today) do
    if length(entries) == length(tuples) do
      entries
      |> Enum.zip(tuples)
      |> Enum.flat_map(fn {entry, tuple} ->
        shape_problems(entry, tuple) ++
          metadata_problems(entry) ++
          expiry_problems(entry, today)
      end)
    else
      []
    end
  end

  defp shape_problems(entry, {file, class, line})
       when is_binary(file) and is_atom(class) do
    location_problem =
      case line do
        line when is_integer(line) ->
          []

        {line, column} when is_integer(line) and is_integer(column) ->
          []

        other ->
          [problem(entry, "location must be `line` or `{line, column}`, got #{inspect(other)}")]
      end

    file_problem =
      if File.regular?(file) do
        []
      else
        [problem(entry, "suppresses #{file}, which does not exist")]
      end

    location_problem ++ file_problem
  end

  defp shape_problems(entry, tuple) do
    [
      problem(
        entry,
        "must be `{file, warning_class, line}`, got #{inspect(tuple)} — " <>
          "file-level and class-level mutes hide warnings nobody has read"
      )
    ]
  end

  defp metadata_problems(entry) do
    for key <- @required_keys, blank?(entry.meta[key]) do
      problem(entry, "missing `# #{key}:` annotation")
    end
  end

  defp expiry_problems(entry, today) do
    case Date.from_iso8601(entry.meta["expires"] || "") do
      {:ok, expires} ->
        if Date.before?(expires, today) do
          [problem(entry, "expired on #{expires} — re-decide it, or re-date it with a reason")]
        else
          []
        end

      {:error, _reason} ->
        # A missing annotation is already reported by metadata_problems/1.
        if blank?(entry.meta["expires"]) do
          []
        else
          [
            problem(
              entry,
              "`# expires:` must be an ISO date, got #{inspect(entry.meta["expires"])}"
            )
          ]
        end
    end
  end

  defp problem(entry, message), do: {entry.line_number, message}

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  # Walks the register as text: comment lines accumulate into the metadata of the entry
  # that follows them, and a blank line ends a block.
  defp parse_entries(contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], %{}, nil}, &scan_line/2)
    |> then(fn {entries, _meta, _key} -> Enum.reverse(entries) end)
  end

  defp scan_line({raw_line, line_number}, {entries, meta, last_key}) do
    line = String.trim(raw_line)

    cond do
      line == "" ->
        {entries, %{}, nil}

      String.starts_with?(line, "#") ->
        scan_comment(line, {entries, meta, last_key})

      line in ["[", "]"] ->
        {entries, %{}, nil}

      true ->
        {[%{line_number: line_number, text: line, meta: meta} | entries], %{}, nil}
    end
  end

  defp scan_comment(line, {entries, meta, last_key}) do
    case Regex.run(~r/^#\s*(#{Enum.join(@required_keys, "|")}):\s*(.*)$/, line) do
      [_, key, value] ->
        {entries, Map.put(meta, key, value), key}

      nil ->
        continuation = String.trim_leading(line, "#") |> String.trim()

        if last_key && continuation != "" do
          {entries, Map.update!(meta, last_key, &(&1 <> " " <> continuation)), last_key}
        else
          {entries, meta, last_key}
        end
    end
  end

  defp eval_register! do
    {tuples, _bindings} = Code.eval_file(@register)
    tuples
  rescue
    error -> abort("cannot evaluate #{@register}: #{Exception.message(error)}")
  end

  defp read_file!(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> abort("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp parse_today(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [today: :string])

    case opts[:today] do
      nil ->
        Date.utc_today()

      value ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _reason} -> abort("--today must be an ISO date, got #{inspect(value)}")
        end
    end
  end

  defp report_ok(entries, today) do
    next = entries |> Enum.map(& &1.meta["expires"]) |> Enum.min(fn -> "none" end)

    IO.puts(
      IO.ANSI.green() <>
        "#{length(entries)}/#{@max_entries} Dialyzer suppressions, all owned and dated " <>
        "(next expiry #{next}, today #{today})." <> IO.ANSI.reset()
    )

    System.halt(0)
  end

  defp report_problems(problems) do
    IO.puts(IO.ANSI.red() <> "Dialyzer suppression register problems:" <> IO.ANSI.reset())
    IO.puts("")

    Enum.each(problems, fn {line_number, message} ->
      location = if line_number, do: "#{@register}:#{line_number}", else: @register
      IO.puts("  #{location}: #{message}")
    end)

    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "Every filter needs `{file, warning_class, line}` plus " <>
        "`# #{Enum.join(@required_keys, ":`, `# ")}:` comments above it." <> IO.ANSI.reset()
    )

    System.halt(1)
  end

  defp abort(message) do
    IO.puts(IO.ANSI.red() <> "Dialyzer suppression check failed: #{message}" <> IO.ANSI.reset())
    System.halt(1)
  end
end

DialyzerFilterChecker.run(System.argv())
