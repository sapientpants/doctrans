defmodule DoctransWeb.ErrorMessagesTest do
  use ExUnit.Case, async: true
  alias Doctrans.Validation
  alias DoctransWeb.ErrorMessages

  defp write_file!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp translated({:error, reason}), do: {:error, ErrorMessages.message(reason)}

  test "translates a background error in the viewer locale" do
    reason = Task.async(fn -> Validation.validate_search_query("") end) |> Task.await()
    assert reason == {:error, :query_too_short}

    Gettext.with_locale(DoctransWeb.Gettext, "de", fn ->
      assert {:error, "Suchanfrage zu kurz"} = translated(reason)

      assert ErrorMessages.message({:pdf_extraction_failed, [reason: :document_not_found]}) ==
               "PDF-Extraktion fehlgeschlagen: Dokument nicht gefunden"
    end)
  end

  test "unknown dependency details never become user-facing messages" do
    message = ErrorMessages.message(:unknown)
    assert ErrorMessages.message({:operation_failed, [reason: "secret response body"]}) == message
    assert ErrorMessages.message(%RuntimeError{message: "private details"}) == message
  end

  describe "localized errors" do
    test "translates errors in every supported non-English locale" do
      translations = %{
        "da" => "Søgningen er for kort",
        "de" => "Suchanfrage zu kurz",
        "es" => "Consulta demasiado corta",
        "fr" => "Requête trop courte",
        "it" => "Query troppo breve",
        "nl" => "Zoekopdracht te kort",
        "no" => "Søket er for kort",
        "pl" => "Zapytanie jest zbyt krótkie",
        "pt" => "Consulta demasiado curta",
        "sv" => "Sökfrågan är för kort"
      }

      for {locale, expected} <- translations do
        Gettext.with_locale(DoctransWeb.Gettext, locale, fn ->
          assert {:error, ^expected} = translated(Validation.validate_search_query(""))
        end)
      end
    end

    test "translates document, query and language errors with bindings" do
      Gettext.with_locale(DoctransWeb.Gettext, "de", fn ->
        assert {:error, "Suchanfrage zu lang (maximal 500 Zeichen)"} =
                 translated(Validation.validate_search_query(String.duplicate("a", 501)))

        assert {:error, "Suchanfrage muss eine Zeichenkette sein"} =
                 translated(Validation.validate_search_query(nil))

        assert {:error, "Nicht unterstützte Sprache: xx"} =
                 translated(Validation.validate_language("xx"))

        assert {:error, "Sprachcode muss eine Zeichenkette sein"} =
                 translated(Validation.validate_language(nil))

        assert {:error, "Erforderliche Felder fehlen: original_filename, target_language"} =
                 translated(Validation.validate_document_attrs(%{title: "Test"}))

        attrs = %{
          title: "",
          original_filename: "test.pdf",
          target_language: "de",
          source_language: "en"
        }

        assert {:error, "Titel darf nicht leer sein"} =
                 translated(Validation.validate_document_attrs(attrs))

        assert {:error, "Titel ist erforderlich und muss eine Zeichenkette sein"} =
                 translated(Validation.validate_document_attrs(%{attrs | title: nil}))

        assert {:error, "Zielsprache ist erforderlich und muss eine Zeichenkette sein"} =
                 translated(
                   Validation.validate_document_attrs(%{
                     attrs
                     | title: "Test",
                       target_language: nil
                   })
                 )

        # A nil source language is "detect it", not a mistake, so the malformed
        # case has to be a value that could never be a language code.
        assert {:ok, _} =
                 Validation.validate_document_attrs(%{
                   attrs
                   | title: "Test",
                     source_language: nil
                 })

        assert {:error, "Quellsprache ist erforderlich und muss eine Zeichenkette sein"} =
                 translated(
                   Validation.validate_document_attrs(%{
                     attrs
                     | title: "Test",
                       source_language: 123
                   })
                 )
      end)

      assert {:error, "Query too short"} = translated(Validation.validate_search_query(""))
    end

    test "document attribute failures have specific messages with resolved bindings in every locale" do
      assert_specific_messages_everywhere([
        :empty_title,
        :invalid_title,
        :invalid_target_language,
        :invalid_source_language
      ])
    end
  end

  describe "extraction limit errors" do
    test "state the value, the limit, and what to do about it" do
      Gettext.with_locale(DoctransWeb.Gettext, "de", fn ->
        assert ErrorMessages.message({:pdf_too_many_pages, [pages: 4200, limit: 1000]}) =~
                 "4200"

        assert ErrorMessages.message({:pdf_too_many_pages, [pages: 4200, limit: 1000]}) =~ "1000"

        assert ErrorMessages.message(
                 {:page_image_too_large, [page_number: 3, size: 40_000_000, limit: 20_000_000]}
               ) =~ "40000000"

        assert ErrorMessages.message({:poppler_not_found, [command: "pdftoppm"]}) =~ "pdftoppm"
      end)
    end

    test "extraction bounds have specific messages with resolved bindings in every locale" do
      reasons = [
        :pdf_command_timeout,
        :pdfinfo_timeout,
        :pdf_extraction_deadline_exceeded,
        {:pdf_too_many_pages, [pages: 4200, limit: 1000]},
        {:page_image_too_large, [page_number: 3, size: 40_000_000, limit: 20_000_000]},
        {:pdf_page_too_large,
         [width: 41_666, height: 41_666, pixels: 1_736_055_556, limit: 40_000_000, dpi: 150]},
        {:poppler_not_found, [command: "pdftoppm"]}
      ]

      assert_specific_messages_everywhere(reasons)
    end

    test "retrieval outages have specific messages with resolved bindings in every locale" do
      # Both spellings: `Doctrans.Chat.retrieve/4` returns the tagged tuple, and
      # the bare atom is what the tuple clause delegates to. Without a clause of
      # its own the tuple would fall through to the generic message and nothing
      # else in the suite would notice.
      assert_specific_messages_everywhere([
        :retrieval_unavailable,
        {:retrieval_unavailable, [reason: :circuit_open]},
        {:retrieval_unavailable, [reason: :database_error]}
      ])
    end

    test "an outage does not read the same as a search that ran and failed" do
      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        # Different surfaces, different scope: global search failing outright
        # versus this document's retrieval being unreachable.
        refute ErrorMessages.message(:retrieval_unavailable) ==
                 ErrorMessages.message(:search_failed)
      end)
    end

    test "a renderer timeout and a reader timeout do not give the same advice" do
      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        # Nothing was rendered when pdfinfo hangs, so "lower the resolution"
        # would be advice the user cannot act on.
        refute ErrorMessages.message(:pdfinfo_timeout) ==
                 ErrorMessages.message(:pdf_command_timeout)
      end)
    end
  end

  describe "file errors" do
    @tag :tmp_dir
    test "translates file validation failures", %{tmp_dir: dir} do
      invalid = write_file!(dir, "invalid.pdf", "not a PDF document")
      tiny = write_file!(dir, "tiny.pdf", "%PD")
      missing = Path.join(dir, "missing.pdf")

      Gettext.with_locale(DoctransWeb.Gettext, "de", fn ->
        assert {:error, "Dateiinhalt stimmt nicht mit der Dateiendung überein"} =
                 translated(Validation.validate_file_content(invalid, ".pdf"))

        assert {:error, "Datei ist zu klein, um ein gültiges Dokument zu sein"} =
                 translated(Validation.validate_file_content(tiny, ".pdf"))

        assert {:error, "Datei konnte nicht zur Validierung gelesen werden"} =
                 translated(Validation.validate_file_content(missing, ".pdf"))

        assert {:error, "Dateipfad und Dateiendung müssen Zeichenketten sein"} =
                 translated(Validation.validate_file_content(nil, ".pdf"))
      end)
    end
  end

  # Catalog completeness and placeholder parity belong to check_translations.exs.
  # Here the runtime mapping must select a specific message in the active locale.
  defp assert_specific_messages_everywhere(reasons) do
    for locale <- Gettext.known_locales(DoctransWeb.Gettext), reason <- reasons do
      Gettext.with_locale(DoctransWeb.Gettext, locale, fn ->
        generic = ErrorMessages.message(:unknown)
        message = ErrorMessages.message(reason)

        assert message != generic,
               "#{inspect(reason)} falls back to the generic message in #{locale}"

        assert message != ""
        # An unresolved placeholder means the translation misspelled a binding.
        refute message =~ "%{", "#{inspect(reason)} has an unresolved binding in #{locale}"
      end)
    end
  end
end
