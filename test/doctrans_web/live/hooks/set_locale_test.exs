defmodule DoctransWeb.Live.Hooks.SetLocaleTest do
  use ExUnit.Case, async: true

  # Gettext keeps the locale in the process dictionary, so the locale this test
  # sets stays in this process and cannot leak into other async tests. It is
  # still reset before each test so an assertion cannot pass on a leftover.

  alias DoctransWeb.Live.Hooks.SetLocale
  alias DoctransWeb.Locale

  setup do
    Gettext.put_locale(DoctransWeb.Gettext, "en")
    :ok
  end

  test "a supported session locale is assigned and applied to the process" do
    assert {:cont, socket} = mount(%{Locale.session_key() => "de"})

    assert socket.assigns.locale == "de"
    assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
  end

  test "every configured locale is honoured" do
    for locale <- Locale.supported() do
      assert {:cont, socket} = mount(%{Locale.session_key() => locale})
      assert socket.assigns.locale == locale
      assert Gettext.get_locale(DoctransWeb.Gettext) == locale
    end
  end

  test "a session without a locale falls back to the default" do
    assert {:cont, socket} = mount(%{})

    assert socket.assigns.locale == Locale.default()
    assert Gettext.get_locale(DoctransWeb.Gettext) == Locale.default()
  end

  test "an unsupported session locale falls back to the default" do
    for value <- ["xx", "", "de-DE", nil] do
      assert {:cont, socket} = mount(%{Locale.session_key() => value})
      assert socket.assigns.locale == Locale.default()
    end
  end

  test "the previous process locale is replaced rather than kept" do
    Gettext.put_locale(DoctransWeb.Gettext, "fr")

    assert {:cont, _socket} = mount(%{Locale.session_key() => "de"})
    assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
  end

  defp mount(session) do
    SetLocale.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})
  end
end
