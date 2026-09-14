defmodule DoctransWeb.Locale do
  @moduledoc """
  Single source of truth for the locales the *interface* is available in.

  This is the UI language, not the set of languages documents can be translated
  into - those live in `Doctrans.Languages` and are a separate concern that
  happens to cover the same codes today.

  The supported list and the default locale come from the `DoctransWeb.Gettext`
  configuration block. Gettext itself does not read `:locales` - it derives its
  known locales from the `priv/gettext` directories - so the two can drift; a
  test asserts they stay equal. The session keys are shared by
  `DoctransWeb.Plugs.SetLocale`, which writes them, and
  `DoctransWeb.Live.Hooks.SetLocale`, which reads them.
  """

  @supported Application.compile_env!(:doctrans, [DoctransWeb.Gettext, :locales])
  @default Application.compile_env!(:doctrans, [DoctransWeb.Gettext, :default_locale])

  @session_key "locale"
  @choice_session_key "locale_choice"

  @doc "Locales the interface has translations for."
  def supported, do: @supported

  @doc "Locale used when nothing else resolves."
  def default, do: @default

  @doc "Session key holding the locale resolved for the current request."
  def session_key, do: @session_key

  @doc """
  Session key holding the locale the user chose explicitly.

  This holds a locale rather than a flag, so that a choice which is temporarily
  unsupported is remembered rather than lost.
  """
  def choice_session_key, do: @choice_session_key

  @doc "Whether a locale is supported. Anything else (nil, garbage, stale values) is not."
  def supported?(locale), do: locale in @supported
end
