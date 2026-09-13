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

        attrs = %{title: "", original_filename: "test.pdf", target_language: "de"}

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
      end)

      assert {:error, "Query too short"} = translated(Validation.validate_search_query(""))
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

    test "a renderer timeout reads as a timeout, not as an unknown failure" do
      generic = ErrorMessages.message(:unknown)

      for locale <- ~w(en de fr) do
        Gettext.with_locale(DoctransWeb.Gettext, locale, fn ->
          message = ErrorMessages.message(:pdf_command_timeout)
          assert message != generic
          assert message != ""
        end)
      end
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
end
