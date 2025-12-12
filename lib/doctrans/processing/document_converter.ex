defmodule Doctrans.Processing.DocumentConverter do
  @moduledoc """
  Converts documents between formats using LibreOffice.

  Primarily used to convert Word documents (.docx) to PDF format
  for processing through the existing PDF extraction pipeline.

  Requires LibreOffice to be installed:
  - macOS: `brew install --cask libreoffice`
  - Ubuntu/Debian: `apt-get install libreoffice-writer-nogui`
  """

  @behaviour Doctrans.Processing.DocumentConverterBehaviour

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  @default_timeout 120_000

  @doc """
  Converts a document file to PDF format using LibreOffice.

  Returns `{:ok, pdf_path}` on success or `{:error, reason}` on failure.

  ## Supported formats

  - `.docx` - Microsoft Word (Open XML)
  - `.doc` - Microsoft Word (Legacy)
  - `.odt` - OpenDocument Text
  - `.rtf` - Rich Text Format
  """
  @impl true
  def convert_to_pdf(source_path, output_dir) do
    if File.exists?(source_path) do
      do_convert(source_path, output_dir)
    else
      {:error, dgettext("errors", "Source file not found: %{path}", path: source_path)}
    end
  end

  defp do_convert(source_path, output_dir) do
    File.mkdir_p!(output_dir)

    soffice_path = get_soffice_path()
    timeout = get_timeout()

    args = [
      "--headless",
      "--convert-to",
      "pdf",
      "--outdir",
      output_dir,
      source_path
    ]

    Logger.info("Converting #{source_path} to PDF in #{output_dir}")

    # Run LibreOffice in headless mode
    # Use Task to handle timeout properly
    task =
      Task.async(fn ->
        System.cmd(soffice_path, args,
          stderr_to_stdout: true,
          env: [{"PATH", System.get_env("PATH")}, {"HOME", System.get_env("HOME")}]
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {_output, 0}} ->
        # LibreOffice outputs the PDF with the same base name as the input
        base_name = Path.basename(source_path, Path.extname(source_path))
        pdf_path = Path.join(output_dir, "#{base_name}.pdf")

        if File.exists?(pdf_path) do
          Logger.info("Successfully converted to #{pdf_path}")
          {:ok, pdf_path}
        else
          {:error, dgettext("errors", "Conversion completed but PDF file not found")}
        end

      {:ok, {error_output, exit_code}} ->
        Logger.error("LibreOffice conversion failed with exit code #{exit_code}: #{error_output}")

        {:error,
         dgettext("errors", "Document conversion failed: %{error}",
           error: String.trim(error_output)
         )}

      nil ->
        Logger.error("LibreOffice conversion timed out after #{timeout}ms")
        {:error, dgettext("errors", "Document conversion timed out")}
    end
  end

  @doc """
  Checks if LibreOffice (soffice) is available on the system.
  """
  @impl true
  def available? do
    case System.find_executable("soffice") do
      nil ->
        # Also check common installation paths
        common_paths = [
          "/Applications/LibreOffice.app/Contents/MacOS/soffice",
          "/usr/bin/soffice",
          "/usr/local/bin/soffice"
        ]

        Enum.any?(common_paths, &File.exists?/1)

      _ ->
        true
    end
  end

  @doc """
  Returns the path to the soffice executable.
  """
  def get_soffice_path do
    config = Application.get_env(:doctrans, :document_conversion, [])
    configured_path = Keyword.get(config, :soffice_path)

    cond do
      configured_path && File.exists?(configured_path) ->
        configured_path

      System.find_executable("soffice") ->
        System.find_executable("soffice")

      File.exists?("/Applications/LibreOffice.app/Contents/MacOS/soffice") ->
        "/Applications/LibreOffice.app/Contents/MacOS/soffice"

      true ->
        "soffice"
    end
  end

  defp get_timeout do
    config = Application.get_env(:doctrans, :document_conversion, [])
    Keyword.get(config, :timeout, @default_timeout)
  end
end
