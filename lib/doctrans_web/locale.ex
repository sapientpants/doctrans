defmodule DoctransWeb.Locale do
  @moduledoc """
  Single source of truth for the locales the web layer supports.

  The supported list and the default locale come from the `DoctransWeb.Gettext`
  configuration block. Gettext itself does not read `:locales` - it derives its
  known locales from the `priv/gettext` directories - so the two can drift; a
  test asserts they stay equal. The session keys are shared by
  `DoctransWeb.Plugs.SetLocale`, which writes them, and
  `DoctransWeb.Live.Hooks.SetLocale`, which reads them.
  """

  @gettext_config Application.compile_env!(:doctrans, DoctransWeb.Gettext)
  @supported Keyword.fetch!(@gettext_config, :locales)
  @default Keyword.fetch!(@gettext_config, :default_locale)

  @session_key "locale"
  @explicit_session_key "locale_explicit"

  @doc "Locales with translations available."
  def supported, do: @supported

  @doc "Locale used when nothing else resolves."
  def default, do: @default

  @doc "Session key holding the resolved locale."
  def session_key, do: @session_key

  @doc "Session key flagging the resolved locale as an explicit user choice."
  def explicit_session_key, do: @explicit_session_key

  @doc "Whether a locale is supported. Anything else (nil, garbage, stale values) is not."
  def supported?(locale), do: locale in @supported
end
