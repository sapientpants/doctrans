defmodule Doctrans.Languages do
  @moduledoc """
  The languages documents can be translated from and into.

  This is the translation list for both directions - a document's source
  language and its target language are drawn from it. It is not the set of
  locales the interface is available in - that is `DoctransWeb.Locale`. The two
  cover the same codes today but are independent: adding an interface
  translation should not silently add a translation language, or the reverse.

  Each code is paired with its English name, the Gettext msgid the interface
  translates it under (`DoctransWeb.DocumentLive.Components.language_name/1`).
  Adding a language here is the whole change on this side: the code joins the
  pickers and the detection prompt, and the name joins the translation catalog
  at the next `mix gettext.extract`.
  """

  @names [
    {"da", "Danish"},
    {"de", "German"},
    {"en", "English"},
    {"es", "Spanish"},
    {"fr", "French"},
    {"it", "Italian"},
    {"nl", "Dutch"},
    {"no", "Norwegian"},
    {"pl", "Polish"},
    {"pt", "Portuguese"},
    {"sv", "Swedish"}
  ]

  @supported Enum.map(@names, fn {code, _name} -> code end)

  @doc "Language codes a document can be translated from or into."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "Each supported code with its English name, in code order."
  @spec names() :: [{String.t(), String.t()}]
  def names, do: @names

  @doc "Whether a language code is a supported translation source or target."
  @spec supported?(term()) :: boolean()
  def supported?(language), do: language in @supported
end
