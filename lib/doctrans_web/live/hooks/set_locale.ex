defmodule DoctransWeb.Live.Hooks.SetLocale do
  @moduledoc """
  LiveView on_mount hook to set the Gettext locale from the session.

  This is necessary because Gettext.put_locale is process-specific, and the
  plug runs in a different process than the LiveView. This hook ensures the
  locale is set in the LiveView process after WebSocket connection.

  The session locale is whatever `DoctransWeb.Plugs.SetLocale` resolved for the
  request that mounted the LiveView: an explicit `lang` choice, the browser's
  Accept-Language preference, or the default. Values that are missing or no
  longer supported fall back to the default locale.
  """

  import Phoenix.Component, only: [assign: 2]

  alias DoctransWeb.Locale

  def on_mount(:default, _params, session, socket) do
    locale = get_locale(session)
    _previous_locale = Gettext.put_locale(DoctransWeb.Gettext, locale)
    {:cont, assign(socket, locale: locale)}
  end

  defp get_locale(session) do
    locale = session[Locale.session_key()]
    if Locale.supported?(locale), do: locale, else: Locale.default()
  end
end
