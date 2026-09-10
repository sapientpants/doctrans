defmodule DoctransWeb.GettextTest do
  use ExUnit.Case, async: true

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
