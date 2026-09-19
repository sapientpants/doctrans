defmodule Scripts.CheckTranslationsTest do
  @moduledoc """
  Covers the pre-commit gate in `scripts/check_translations.exs`.

  The gate's only failure mode that matters is passing a file it should reject,
  and the shapes that used to slip through it -- a wrapped `msgid ""`, a fuzzy
  flag on an obsolete block, a fuzzy entry in the source language -- all look
  ordinary in a diff. Each one gets a fixture here.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # The script guards its own invocation in :test, so requiring it yields the
  # module without running the check against the real priv/gettext.
  Code.require_file("../../scripts/check_translations.exs", __DIR__)

  describe "completeness" do
    test "a fully translated tree reports nothing", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Hello"\nmsgstr "Hallo"\n))

      assert %{missing: [], fuzzy: [], problems: []} = TranslationChecker.check(dir)
    end

    test "an empty msgstr is missing", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Hello"\nmsgstr ""\n))

      assert %{missing: [{"de", "default", "Hello"}], fuzzy: []} = TranslationChecker.check(dir)
    end

    test "a msgid absent from the po file is missing", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Other"\nmsgstr "Andere"\n))

      assert %{missing: [{"de", "default", "Hello"}]} = TranslationChecker.check(dir)
    end

    test "a missing po file reports every entry", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n\nmsgid "Bye"\nmsgstr ""\n))
      File.mkdir_p!(Path.join([dir, "de", "LC_MESSAGES"]))

      assert %{missing: [{"de", "default", "Hello"}, {"de", "default", "Bye"}]} =
               TranslationChecker.check(dir)
    end

    test "the source language is exempt -- an empty en msgstr falls back to the msgid",
         %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "en", ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Hello"\nmsgstr "Hallo"\n))

      assert %{missing: [], fuzzy: []} = TranslationChecker.check(dir)
    end

    test "a wrapped msgid is checked, not mistaken for the header entry", %{tmp_dir: dir} do
      pot(dir, ~s(msgid ""\n"A source string long enough that gettext wraps it"\nmsgstr ""\n))

      po(
        dir,
        "de",
        ~s(msgid ""\n"A source string long enough that gettext wraps it"\nmsgstr ""\n)
      )

      assert %{missing: [{"de", "default", "A source string long enough that gettext wraps it"}]} =
               TranslationChecker.check(dir)
    end

    test "every plural form must be translated, not just one", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "One"\nmsgid_plural "Many"\nmsgstr[0] ""\nmsgstr[1] ""\n))
      po(dir, "de", ~s(msgid "One"\nmsgid_plural "Many"\nmsgstr[0] "Eins"\nmsgstr[1] ""\n))

      assert %{missing: [{"de", "default", "One"}]} = TranslationChecker.check(dir)
    end

    test "a fully translated plural passes", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "One"\nmsgid_plural "Many"\nmsgstr[0] ""\nmsgstr[1] ""\n))
      po(dir, "de", ~s(msgid "One"\nmsgid_plural "Many"\nmsgstr[0] "Eins"\nmsgstr[1] "Viele"\n))

      assert %{missing: [], fuzzy: []} = TranslationChecker.check(dir)
    end

    test "msgctxt distinguishes two entries sharing a msgid", %{tmp_dir: dir} do
      pot(
        dir,
        ~s(msgctxt "verb"\nmsgid "Sort"\nmsgstr ""\n\nmsgctxt "noun"\nmsgid "Sort"\nmsgstr ""\n)
      )

      po(dir, "de", ~s(msgctxt "verb"\nmsgid "Sort"\nmsgstr "Sortieren"\n))

      assert %{missing: [{"de", "default", "noun | Sort"}]} = TranslationChecker.check(dir)
    end

    test "an obsolete entry does not satisfy the completeness check", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "de", ~s(#~ msgid "Hello"\n#~ msgstr "Hallo"\n))

      assert %{missing: [{"de", "default", "Hello"}]} = TranslationChecker.check(dir)
    end
  end

  describe "fuzzy" do
    test "a fuzzy entry is rejected even though its msgstr is filled in", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Danish"\nmsgstr ""\n))
      po(dir, "de", ~s(#, fuzzy\nmsgid "Danish"\nmsgstr "Spanisch"\n))

      assert %{fuzzy: [{"de", "default", "Danish"}], missing: []} = TranslationChecker.check(dir)
    end

    test "a fuzzy entry in the source language is rejected", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Sort documents"\nmsgstr ""\n))
      po(dir, "en", ~s(#, fuzzy\nmsgid "Sort documents"\nmsgstr "Search documents"\n))
      po(dir, "de", ~s(msgid "Sort documents"\nmsgstr "Dokumente sortieren"\n))

      assert %{fuzzy: [{"en", "default", "Sort documents"}]} = TranslationChecker.check(dir)
    end

    test "a fuzzy entry on a wrapped msgid is rejected", %{tmp_dir: dir} do
      pot(dir, ~s(msgid ""\n"Drag and drop documents here, or"\nmsgstr ""\n))

      po(
        dir,
        "de",
        ~s(#, elixir-autogen, fuzzy\nmsgid ""\n"Drag and drop documents here, or"\nmsgstr "PDF-Dateien hierher ziehen"\n)
      )

      assert %{fuzzy: [{"de", "default", "Drag and drop documents here, or"}]} =
               TranslationChecker.check(dir)
    end

    test "a fuzzy flag on an obsolete block is not charged to the next live entry",
         %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Live"\nmsgstr ""\n))

      po(
        dir,
        "de",
        ~s(#, fuzzy\n#~ msgid "Removed"\n#~ msgstr "Entfernt"\n\nmsgid "Live"\nmsgstr "Lebendig"\n)
      )

      assert %{fuzzy: [], missing: []} = TranslationChecker.check(dir)
    end

    test "a fuzzy flag on the header entry is ignored", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))

      po(
        dir,
        "de",
        ~s(#, fuzzy\nmsgid ""\nmsgstr ""\n"Language: de\\n"\n\nmsgid "Hello"\nmsgstr "Hallo"\n)
      )

      assert %{fuzzy: [], missing: []} = TranslationChecker.check(dir)
    end

    test "flags that merely contain other words do not trip the check", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))

      po(
        dir,
        "de",
        ~s(#, elixir-autogen, elixir-format, no-wrap\nmsgid "Hello"\nmsgstr "Hallo"\n)
      )

      assert %{fuzzy: []} = TranslationChecker.check(dir)
    end

    test "fuzzy is reported per domain", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      File.write!(Path.join(dir, "errors.pot"), ~s(msgid "Boom"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Hello"\nmsgstr "Hallo"\n))
      po(dir, "de", ~s(#, fuzzy\nmsgid "Boom"\nmsgstr "Knall"\n), "errors")

      assert %{fuzzy: [{"de", "errors", "Boom"}], missing: []} = TranslationChecker.check(dir)
    end
  end

  describe "interpolation bindings" do
    test "a translation keeping every binding passes", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Sent to %{host}"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Sent to %{host}"\nmsgstr "Gesendet an %{host}"\n))

      assert %{bindings: [], missing: [], fuzzy: []} = TranslationChecker.check(dir)
    end

    test "a translation dropping a binding is rejected", %{tmp_dir: dir} do
      # The failure this check exists for: Gettext logs and renders, so the
      # sentence ships with the destination silently missing.
      pot(dir, ~s(msgid "Sent to %{host}"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Sent to %{host}"\nmsgstr "Gesendet"\n))

      assert %{bindings: [{"de", "default", issue}], missing: [], fuzzy: []} =
               TranslationChecker.check(dir)

      assert issue =~ "Sent to %{host}"
      assert issue =~ "msgstr drops %{host}"
    end

    test "a translation renaming a binding is rejected", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Sent to %{host}"\nmsgstr ""\n))
      po(dir, "fr", ~s(msgid "Sent to %{host}"\nmsgstr "Envoyé à %{hôte}"\n))

      assert %{bindings: [{"fr", "default", issue}]} = TranslationChecker.check(dir)
      assert issue =~ "drops %{host}"
    end

    test "an empty msgstr is missing, not a binding mismatch", %{tmp_dir: dir} do
      # It falls back to the msgid, which carries the right bindings already;
      # reporting it twice would just make the missing-translation report noisier.
      pot(dir, ~s(msgid "Sent to %{host}"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Sent to %{host}"\nmsgstr ""\n))

      assert %{bindings: [], missing: [{"de", "default", "Sent to %{host}"}]} =
               TranslationChecker.check(dir)
    end

    test "the source language's empty msgstr is not a binding mismatch", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Sent to %{host}"\nmsgstr ""\n))
      po(dir, "en", ~s(msgid "Sent to %{host}"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Sent to %{host}"\nmsgstr "Gesendet an %{host}"\n))

      assert %{bindings: [], missing: [], fuzzy: []} = TranslationChecker.check(dir)
    end

    test "each plural form is compared against the source it renders", %{tmp_dir: dir} do
      # msgstr[0] answers the msgid, higher forms answer msgid_plural -- comparing
      # every form against the msgid would mis-report a correct plural.
      pot(
        dir,
        ~s(msgid "%{count} file on %{host}"\nmsgid_plural "%{count} files on %{host}"\n) <>
          ~s(msgstr[0] ""\nmsgstr[1] ""\n)
      )

      po(
        dir,
        "de",
        ~s(msgid "%{count} file on %{host}"\nmsgid_plural "%{count} files on %{host}"\n) <>
          ~s(msgstr[0] "%{count} Datei auf %{host}"\nmsgstr[1] "%{count} Dateien"\n)
      )

      assert %{bindings: [{"de", "default", issue}], missing: []} = TranslationChecker.check(dir)
      assert issue =~ "msgstr[1] drops %{host}"
    end

    test "an obsolete entry's bindings are not checked", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Sent to %{host}"\nmsgstr ""\n))

      po(
        dir,
        "de",
        ~s(msgid "Sent to %{host}"\nmsgstr "Gesendet an %{host}"\n\n) <>
          ~s(#~ msgid "Old %{host}"\n#~ msgstr "Alt"\n)
      )

      assert %{bindings: []} = TranslationChecker.check(dir)
    end
  end

  describe "configuration guards" do
    test "a tree with no pot files is a problem, not a pass", %{tmp_dir: dir} do
      po(dir, "de", ~s(msgid "Hello"\nmsgstr "Hallo"\n))

      assert %{problems: [problem]} = TranslationChecker.check(dir)
      assert problem =~ "No POT files found"
    end

    test "a tree with no translated languages is a problem, not a pass", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))

      assert %{problems: [problem]} = TranslationChecker.check(dir)
      assert problem =~ "No language directories found"
    end

    test "fuzzy in en is still caught when en is the only locale", %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "en", ~s(#, fuzzy\nmsgid "Hello"\nmsgstr "Borrowed"\n))

      assert %{fuzzy: [{"en", "default", "Hello"}], problems: [_]} = TranslationChecker.check(dir)
    end

    test "loose files beside the locale directories are not treated as languages",
         %{tmp_dir: dir} do
      pot(dir, ~s(msgid "Hello"\nmsgstr ""\n))
      po(dir, "de", ~s(msgid "Hello"\nmsgstr "Hallo"\n))
      File.write!(Path.join(dir, "README.md"), "not a locale")

      assert %{language_dirs: ["de"], problems: []} = TranslationChecker.check(dir)
    end
  end

  defp pot(dir, contents), do: File.write!(Path.join(dir, "default.pot"), contents)

  defp po(dir, lang, contents, domain \\ "default") do
    lc_messages = Path.join([dir, lang, "LC_MESSAGES"])
    File.mkdir_p!(lc_messages)
    File.write!(Path.join(lc_messages, "#{domain}.po"), contents)
  end
end
