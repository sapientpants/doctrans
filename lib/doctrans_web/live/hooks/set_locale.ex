defmodule DoctransWeb.Live.Hooks.SetLocale do
  @moduledoc """
  LiveView on_mount hook to set the Gettext locale from the session.

  This is necessary because Gettext.put_locale is process-specific, and the
  plug runs in a different process than the LiveView. This hook ensures the
  locale is set in the LiveView process after WebSocket connection.
  """

  import Phoenix.Component, only: [assign: 2]

  @supported_locales ~w(da de en es fr it nl no pl pt sv)
  @default_locale "en"

  def on_mount(:default, _params, session, socket) do
    locale = get_locale(session)
    Gettext.put_locale(DoctransWeb.Gettext, locale)
    {:cont, assign(socket, locale: locale)}
  end

  defp get_locale(session) do
    case session["locale"] do
      locale when locale in @supported_locales -> locale
      _ -> @default_locale
    end
  end
end
