defmodule Doctrans.Documents.Formats do
  @moduledoc """
  The file formats a document can be uploaded in.

  One list, read everywhere a format is accepted or routed: the upload picker,
  the extraction job's guard, the stored-original path, and the processor that
  decides whether a file goes to the PDF extractor directly or through
  LibreOffice first, and the import filter it goes through there. Extensions are
  lowercase and carry their leading dot, the shape `Path.extname/1` returns once
  downcased.
  """

  @pdf ".pdf"

  # The Writer import filter each convertible extension is converted through.
  # Without `--infilter` LibreOffice picks the importer from the file's content,
  # and the upload check only reads its first bytes -- a ZIP or OLE2 header any
  # office format shares -- so a spreadsheet named `.docx` would reach Calc.
  # Naming the filter holds every upload to the Writer importer its extension
  # implies.
  @import_filters %{
    ".doc" => "MS Word 97",
    ".docx" => "MS Word 2007 XML",
    ".odt" => "writer8",
    ".rtf" => "Rich Text Format"
  }

  @convertible @import_filters |> Map.keys() |> Enum.sort()
  @supported [@pdf | @convertible]

  @doc "Every extension an upload may carry."
  @spec supported_extensions() :: [String.t()]
  def supported_extensions, do: @supported

  @doc "The extensions that are converted to PDF before extraction."
  @spec convertible_extensions() :: [String.t()]
  def convertible_extensions, do: @convertible

  @doc "The LibreOffice import filter a convertible extension is converted through."
  @spec import_filter(String.t()) :: {:ok, String.t()} | :error
  def import_filter(extension), do: Map.fetch(@import_filters, extension)

  @doc "Whether a lowercase, dotted extension is one an upload may carry."
  @spec supported?(term()) :: boolean()
  def supported?(extension), do: extension in @supported

  @doc "The lowercase, dotted extension of a path, as the other predicates expect it."
  @spec extension(Path.t()) :: String.t()
  def extension(path), do: path |> Path.extname() |> String.downcase()

  @doc "Whether a path is a PDF, which goes to the extractor without conversion."
  @spec pdf?(Path.t()) :: boolean()
  def pdf?(path), do: extension(path) == @pdf
end
