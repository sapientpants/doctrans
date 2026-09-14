defmodule Doctrans.Languages do
  @moduledoc """
  The languages documents can be translated into.

  This is the translation target list, not the set of locales the interface is
  available in - that is `DoctransWeb.Locale`. The two cover the same codes
  today but are independent: adding an interface translation should not silently
  add a translation target, or the reverse.
  """

  @supported ~w(da de en es fr it nl no pl pt sv)

  @doc "Language codes a document can be translated into."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "Whether a language code is a supported translation target."
  @spec supported?(term()) :: boolean()
  def supported?(language), do: language in @supported
end
