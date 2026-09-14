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

  test "a supported session locale is applied to the process" do
    assert {:cont, _socket} = mount(%{Locale.session_key() => "de"})

    assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
  end

  test "every configured locale is honoured" do
    for locale <- Locale.supported() do
      assert {:cont, _socket} = mount(%{Locale.session_key() => locale})
      assert Gettext.get_locale(DoctransWeb.Gettext) == locale
    end
  end

  test "a session without a locale falls back to the default" do
    Gettext.put_locale(DoctransWeb.Gettext, "fr")

    assert {:cont, _socket} = mount(%{})

    assert Gettext.get_locale(DoctransWeb.Gettext) == Locale.default()
  end

  test "an unsupported session locale falls back to the default" do
    for value <- ["xx", "", "de-DE", nil] do
      Gettext.put_locale(DoctransWeb.Gettext, "fr")

      assert {:cont, _socket} = mount(%{Locale.session_key() => value})
      assert Gettext.get_locale(DoctransWeb.Gettext) == Locale.default()
    end
  end

  test "the previous process locale is replaced rather than kept" do
    Gettext.put_locale(DoctransWeb.Gettext, "fr")

    assert {:cont, _socket} = mount(%{Locale.session_key() => "de"})
    assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
  end

  test "the hook reads the locale, not the stored choice" do
    # The plug resolves the choice; the hook only mirrors what was resolved, so
    # a stale choice in the session must not reach the LiveView process.
    assert {:cont, _socket} =
             mount(%{Locale.session_key() => "de", Locale.choice_session_key() => "xx"})

    assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
  end

  defp mount(session) do
    SetLocale.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})
  end
end
