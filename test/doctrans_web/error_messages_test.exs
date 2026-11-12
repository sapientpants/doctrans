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

  describe "the generic fallback" do
    test "is neutral copy that reads the same bare and nested" do
      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        generic = ErrorMessages.message(:unknown)

        # Not the chat assistant's first person: the same text ends up in a flash
        # and next to a page number.
        refute generic =~ ~r/\b(I|Sorry)\b/

        assert ErrorMessages.message(
                 {:page_extraction_failed, [page_number: 3, reason: :unknown]}
               ) ==
                 "Page 3 extraction failed: " <> generic
      end)
    end

    test "message/2 substitutes the caller's fallback only for reasons without an entry" do
      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        assert ErrorMessages.message(:unknown, "custom fallback") == "custom fallback"

        assert ErrorMessages.message({:operation_failed, [reason: "detail"]}, "custom fallback") ==
                 "custom fallback"

        assert ErrorMessages.message(:document_not_found, "custom fallback") ==
                 ErrorMessages.message(:document_not_found)
      end)
    end

    test "the model list failure names the model server, not a vendor" do
      for locale <- Gettext.known_locales(DoctransWeb.Gettext) do
        Gettext.with_locale(DoctransWeb.Gettext, locale, fn ->
          refute ErrorMessages.message(:models_unavailable) =~ "OpenAI"
        end)
      end
    end

    # The catalog is one gettext domain. A message extracted into `default.pot`
    # would split error strings across two PO files per locale again.
    test "every message is extracted into the errors domain" do
      refute File.read!("priv/gettext/default.pot") =~ "lib/doctrans_web/error_messages.ex"
      assert File.read!("priv/gettext/errors.pot") =~ "lib/doctrans_web/error_messages.ex"
    end
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

        assert {:error, "Frage zu lang (maximal 4000 Zeichen)"} =
                 translated(Validation.validate_chat_question(String.duplicate("a", 4_001)))

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
         [
           page_number: 7,
           width: 41_666,
           height: 41_666,
           pixels: 1_736_055_556,
           limit: 40_000_000,
           dpi: 150
         ]},
        {:poppler_not_found, [command: "pdftoppm"]},
        :invalid_page_count,
        :invalid_page_size
      ]

      assert_specific_messages_everywhere(reasons)
    end

    test "an extraction run that ended without a verdict has specific messages in every locale" do
      assert_specific_messages_everywhere([
        {:extraction_job_crashed, [error: "Doctrans.Jobs.DocumentExtractionJob timed out"]},
        {:extraction_attempts_exhausted, [attempts: 3, error: "** (RuntimeError) boom"]},
        {:extraction_attempts_exhausted, [attempts: 3]}
      ])
    end

    test "the raw error of a crashed extraction run stays on the row, not in the copy" do
      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        refute ErrorMessages.message({:extraction_job_crashed, [error: ":killed"]}) =~ "killed"

        refute ErrorMessages.message(
                 {:extraction_attempts_exhausted, [attempts: 3, error: "private details"]}
               ) =~ "private"
      end)
    end

    test "inference bounds have specific messages with resolved bindings in every locale" do
      assert_specific_messages_everywhere([
        :inference_deadline_exceeded,
        {:inference_response_too_large, [limit: 8_000_000]},
        {:inference_response_too_fragmented, [limit: 20_000]},
        :invalid_endpoint_url
      ])
    end

    test "retrieval outages have specific messages with resolved bindings in every locale" do
      # Both spellings: `Doctrans.Chat.Retrieval.retrieve/3` returns the tagged tuple, and
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

    test "a database outage has a specific message that names no operation" do
      # Reached from cancellation, reprocessing and `Repo.safe_transaction/1`;
      # the search paths remap to `:search_failed` / `:retrieval_unavailable`
      # before they get here, so "failed to search" would be the wrong story.
      assert_specific_messages_everywhere([
        :database_error,
        {:database_error, [reason: %DBConnection.ConnectionError{message: "closed"}]}
      ])

      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        refute ErrorMessages.message(:database_error) =~ ~r/search/i
      end)
    end

    test "a pdftoppm failure nested in an extraction failure does not repeat the prefix" do
      Gettext.with_locale(DoctransWeb.Gettext, "en", fn ->
        assert ErrorMessages.message(
                 {:pdf_extraction_failed, [reason: {:pdf_command_failed, [error: "boom"]}]}
               ) == "PDF extraction failed: pdftoppm failed: boom"
      end)
    end

    test "a reason no producer emits has no entry of its own" do
      # `:reprocess_failed` left with the page-reset flow; keeping its clause
      # would keep a msgid live in every catalog for text nobody can see.
      assert ErrorMessages.message(:reprocess_failed) == ErrorMessages.message(:unknown)
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
