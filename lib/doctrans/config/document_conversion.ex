defmodule Doctrans.Config.DocumentConversion do
  @moduledoc """
  Typed access to the LibreOffice conversion settings.

  Every default is stated here and nowhere else: `config/config.exs` explains
  what each key is for and sets only the keys a deployment overrides, mirroring
  `Doctrans.Config.PdfExtraction`.
  """

  alias Doctrans.Config

  @default_timeout 120_000

  # Known install locations, checked when `soffice` is not on `PATH`: a daemon
  # started with a slim environment still finds a Homebrew, cask or distro
  # LibreOffice. Configurable so a deployment can pin or disable them.
  @default_search_paths [
    "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    "/usr/bin/soffice",
    "/usr/local/bin/soffice",
    "/opt/homebrew/bin/soffice"
  ]

  @doc "Milliseconds a conversion may take before the soffice process is killed."
  @spec timeout() :: pos_integer()
  def timeout, do: setting(:timeout, @default_timeout)

  @doc "An explicit path to the soffice executable, or `nil` to resolve it normally."
  @spec soffice_path() :: String.t() | nil
  def soffice_path, do: setting(:soffice_path, nil)

  @doc "Absolute executable paths to try when `PATH` has no `soffice`."
  @spec search_paths() :: [String.t()]
  def search_paths, do: setting(:search_paths, @default_search_paths)

  defp setting(key, default) do
    case Config.get(:document_conversion, key) do
      nil -> default
      value -> value
    end
  end
end
