defmodule Doctrans.Documents.Formats do
  @moduledoc """
  The file formats a document can be uploaded in.

  One list, read everywhere a format is accepted or routed: the upload picker,
  the extraction job's guard, the stored-original path, and the processor that
  decides whether a file goes to the PDF extractor directly or through
  LibreOffice first. Extensions are lowercase and carry their leading dot, the
  shape `Path.extname/1` returns once downcased.
  """

  @pdf ".pdf"
  @convertible ~w(.doc .docx .odt .rtf)
  @supported [@pdf | @convertible]

  @doc "Every extension an upload may carry."
  @spec supported_extensions() :: [String.t()]
  def supported_extensions, do: @supported

  @doc "The extensions that are converted to PDF before extraction."
  @spec convertible_extensions() :: [String.t()]
  def convertible_extensions, do: @convertible

  @doc "Whether a lowercase, dotted extension is one an upload may carry."
  @spec supported?(term()) :: boolean()
  def supported?(extension), do: extension in @supported

  @doc "The lowercase, dotted extension of a path, as the other predicates expect it."
  @spec extension(Path.t()) :: String.t()
  def extension(path), do: path |> Path.extname() |> String.downcase()
end
