defmodule DoctransWeb.GettextTest do
  use ExUnit.Case, async: true

  # `DoctransWeb.Locale` reads the supported list from the `DoctransWeb.Gettext`
  # config block, but Gettext derives its own known locales from `priv/gettext`
  # and ignores that key, so the two can drift: a locale in config without a PO
  # directory renders untranslated English under its own `<html lang>`, and one
  # in `priv/` without config is unreachable.
  test "the configured locales are exactly the ones Gettext knows" do
    assert Enum.sort(DoctransWeb.Locale.supported()) ==
             Enum.sort(Gettext.known_locales(DoctransWeb.Gettext))

    assert DoctransWeb.Locale.default() in DoctransWeb.Locale.supported()
  end

  test "search pagination interpolates page numbers in every locale" do
    for locale <- Gettext.known_locales(DoctransWeb.Gettext) do
      Gettext.with_locale(DoctransWeb.Gettext, locale, fn ->
        label =
          Gettext.dgettext(DoctransWeb.Gettext, "default", "Page %{page} of %{total}",
            page: 2,
            total: 3
          )

        assert label =~ "2", "missing current page in #{locale}: #{label}"
        assert label =~ "3"
        refute label =~ "%{"
      end)
    end
  end
end
