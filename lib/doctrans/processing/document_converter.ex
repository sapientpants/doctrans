defmodule Doctrans.Processing.DocumentConverter do
  @moduledoc """
  Converts documents to PDF using LibreOffice with a separate profile per run.

  `Doctrans.Processing.Subprocess` enforces the deadline, bounds captured
  diagnostics, and kills the conversion's process group — including anything the
  launcher left behind — whether it exits, times out, or the caller dies.

  Profiles are created privately and exclusively using `/usr/bin/mktemp`,
  available on the supported macOS and Linux installations.
  """

  @behaviour Doctrans.Processing.DocumentConverterBehaviour

  require Logger

  alias Doctrans.Processing.Subprocess

  @default_timeout 120_000
  @search_paths [
    "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    "/usr/bin/soffice",
    "/usr/local/bin/soffice",
    "/opt/homebrew/bin/soffice"
  ]

  @impl true
  def available? do
    match?({:ok, _}, resolve_soffice_path())
  end

  @impl true
  def convert_to_pdf(source_path, output_dir) do
    if File.exists?(source_path) do
      case resolve_soffice_path() do
        {:ok, path} ->
          supervise_conversion(path, source_path, output_dir)

        {:error, _} ->
          Logger.error("LibreOffice is not installed")
          {:error, :soffice_not_found}
      end
    else
      {:error, {:source_file_not_found, [path: source_path]}}
    end
  end

  # Resolves the path of the soffice executable.
  #
  # Search order:
  #
  #   1. `:soffice_path` from `config :doctrans, :document_conversion`
  #      when it points at an existing, executable file.
  #   2. The first `soffice` found on `PATH`.
  #   3. Absolute executable entries in `:search_paths`.
  #
  # Returns `{:ok, path}` or `{:error, :soffice_not_found}`.
  @spec resolve_soffice_path() :: {:ok, String.t()} | {:error, :soffice_not_found}
  def resolve_soffice_path do
    config = Application.get_env(:doctrans, :document_conversion, [])
    configured = Keyword.get(config, :soffice_path)
    search_paths = Keyword.get(config, :search_paths, @search_paths)

    found =
      if executable_file?(configured) do
        configured
      else
        find_on_path("soffice") || Enum.find(search_paths, &absolute_executable?/1)
      end

    case found do
      nil -> {:error, :soffice_not_found}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp absolute_executable?(path),
    do: is_binary(path) and Path.type(path) == :absolute and executable_file?(path)

  # Locates `name` by searching the directories in the current `PATH`,
  # honouring whatever PATH the process environment holds at call time.
  # Returns the absolute path or `nil`.
  defp find_on_path(name) do
    path_var = System.get_env("PATH", "")

    separator =
      case :os.type() do
        {:win32, _} -> ";"
        _other -> ":"
      end

    path_var
    |> String.split(separator, trim: false)
    |> Enum.map(fn dir -> Path.join(dir, name) end)
    |> Enum.find(&executable_file?/1)
  end

  defp supervise_conversion(path, source_path, output_dir) do
    # The profile is created inside the supervised process so a caller killed
    # mid-conversion still has it removed.
    case Subprocess.supervised(fn -> run_conversion(path, source_path, output_dir) end) do
      {:subprocess_owner_down, reason} -> finalize({:error, reason}, nil, nil)
      result -> result
    end
  end

  # The output directory comes from the stored upload path; profile_dir is created by mktemp.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_conversion(soffice_path, source_path, output_dir) do
    File.mkdir_p!(output_dir)

    timeout = get_timeout()
    profile_dir = create_profile_dir!()

    args = [
      "-env:UserInstallation=" <> profile_uri(profile_dir),
      "--headless",
      "--convert-to",
      "pdf",
      "--outdir",
      output_dir,
      source_path
    ]

    base_name = Path.basename(source_path, Path.extname(source_path))
    pdf_path = Path.join(output_dir, "#{base_name}.pdf")

    Logger.info("Converting #{source_path} to PDF in #{output_dir} using #{soffice_path}")

    result =
      try do
        Subprocess.run(soffice_path, args, timeout: timeout)
      after
        # Remove the throwaway profile whether the conversion succeeded,
        # failed, or was killed.
        File.rm_rf(profile_dir)
      end

    finalize(result, pdf_path, timeout)
  end

  defp finalize({:ok, {_output, 0}}, pdf_path, _timeout) do
    if File.exists?(pdf_path) do
      Logger.info("Successfully converted to #{pdf_path}")
      {:ok, pdf_path}
    else
      {:error, :converted_pdf_not_found}
    end
  end

  defp finalize({:ok, {output, exit_code}}, _pdf_path, _timeout) do
    Logger.error(
      "LibreOffice conversion failed with exit code #{exit_code}: " <>
        String.slice(output, 0, 500)
    )

    {:error, {:conversion_failed, [error: String.trim(output)]}}
  end

  defp finalize({:start_error, reason}, _pdf_path, _timeout) do
    {:error, {:conversion_start_failed, [error: String.trim(reason)]}}
  end

  defp finalize({:error, reason}, _pdf_path, _timeout) do
    {:error, {:conversion_start_failed, [error: reason]}}
  end

  defp finalize({:timeout, output}, _pdf_path, timeout) do
    Logger.error(
      "LibreOffice conversion timed out after #{timeout}ms: " <> String.slice(output, 0, 500)
    )

    {:error, :conversion_timeout}
  end

  # Creates a throwaway LibreOffice profile for a single conversion.
  #
  # Sharing the user's profile (LibreOffice's default) makes concurrent
  # conversions — or a conversion running while the user has LibreOffice
  # open — block on the profile lock. A per-run profile is always free.
  defp create_profile_dir! do
    template = Path.join(System.tmp_dir!(), "doctrans-soffice-XXXXXXXXXX")

    # mktemp atomically creates a fresh mode-0700 directory on macOS and Linux.
    # mkdir_p would accept an existing directory; mkdir followed by chmod would
    # leave a permissions window when the application's umask is permissive.
    case System.cmd("/usr/bin/mktemp", ["-d", template], stderr_to_stdout: true, env: []) do
      {path, 0} -> String.trim_trailing(path, "\n")
      {error, _status} -> raise "Failed to create LibreOffice profile: #{String.trim(error)}"
    end
  end

  # Encodes the profile path as a file:// URI, escaping each path segment so
  # spaces or non-ASCII characters in the temp directory do not break it.
  defp profile_uri(profile_dir) do
    encoded =
      profile_dir
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))

    "file://" <> encoded
  end

  # Returns the configured timeout in milliseconds.
  defp get_timeout do
    config = Application.get_env(:doctrans, :document_conversion, [])
    Keyword.get(config, :timeout, @default_timeout)
  end

  # Returns true when `path` points at an existing, executable regular file.
  defp executable_file?(path) do
    is_binary(path) and executable_stats?(path)
  end

  defp executable_stats?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> :erlang.band(mode, 0o111) != 0
      _other -> false
    end
  end
end
