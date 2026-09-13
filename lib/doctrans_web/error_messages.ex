defmodule DoctransWeb.ErrorMessages do
  @moduledoc "Translates domain error reasons in the calling web process's locale."
  use Gettext, backend: DoctransWeb.Gettext

  @spec message(term()) :: String.t()
  def message(:query_too_short), do: dgettext("errors", "Query too short")

  def message({:query_too_long, bindings}),
    do: dgettext("errors", "Query too long (max %{max} characters)", max: binding(bindings, :max))

  def message(:invalid_query), do: dgettext("errors", "Search query must be a string")

  def message({:unsupported_language, bindings}),
    do:
      dgettext("errors", "Unsupported language: %{language}",
        language: binding(bindings, :language)
      )

  def message(:invalid_language), do: dgettext("errors", "Language code must be a string")

  def message(:file_content_mismatch),
    do: dgettext("errors", "File content does not match its extension")

  def message(:file_too_small), do: dgettext("errors", "File is too small to be a valid document")

  def message(:file_unreadable), do: dgettext("errors", "Could not read file for validation")

  def message(:invalid_file_arguments),
    do: dgettext("errors", "File path and extension must be strings")

  def message({:missing_required_fields, bindings}),
    do:
      dgettext("errors", "Missing required fields: %{fields}", fields: binding(bindings, :fields))

  def message(:empty_title), do: dgettext("errors", "Title cannot be empty")

  def message(:invalid_title), do: dgettext("errors", "Title is required and must be a string")

  def message(:invalid_target_language),
    do: dgettext("errors", "Target language is required and must be a string")

  def message(:document_not_found), do: dgettext("errors", "Document not found")

  def message(:incomplete_output),
    do:
      dgettext(
        "errors",
        "The model did not return complete final text. Use a model with a larger output budget or split the page into smaller sections, then reprocess. The provider must return finish_reason=stop."
      )

  def message(:page_not_found), do: dgettext("errors", "Page not found")

  def message({:page_extraction_failed, bindings}),
    do:
      dgettext("errors", "Page %{page_number} extraction failed: %{reason}",
        page_number: binding(bindings, :page_number),
        reason: binding(bindings, :reason)
      )

  def message({:page_translation_failed, bindings}),
    do:
      dgettext("errors", "Page %{page_number} translation failed: %{reason}",
        page_number: binding(bindings, :page_number),
        reason: binding(bindings, :reason)
      )

  def message({:pages_failed, bindings}),
    do:
      dgettext(
        "errors",
        "Processing failed on page(s) %{page_numbers}. Reprocess those pages to finish this document.",
        page_numbers: binding(bindings, :page_numbers)
      )

  def message({:unsupported_format, bindings}),
    do:
      dgettext("errors", "Unsupported file format: %{format}", format: binding(bindings, :format))

  def message({:pdf_extraction_failed, bindings}),
    do: dgettext("errors", "PDF extraction failed: %{reason}", reason: binding(bindings, :reason))

  def message({:pdf_command_failed, bindings}),
    do: dgettext("errors", "PDF extraction failed: %{error}", error: binding(bindings, :error))

  def message(:page_image_not_found),
    do: dgettext("errors", "Page image not found after extraction")

  def message(:invalid_page_count),
    do: dgettext("errors", "Could not parse page count from pdfinfo output")

  def message({:pdfinfo_failed, bindings}),
    do: dgettext("errors", "pdfinfo failed: %{error}", error: binding(bindings, :error))

  def message(:pdf_command_timeout),
    do:
      dgettext(
        "errors",
        "PDF rendering timed out. Lower the extraction resolution or split the document, then try again."
      )

  def message({:pdf_too_many_pages, bindings}),
    do:
      dgettext(
        "errors",
        "This PDF has %{pages} pages, above the limit of %{limit}. Split it into smaller documents before uploading.",
        pages: binding(bindings, :pages),
        limit: binding(bindings, :limit)
      )

  def message({:page_image_too_large, bindings}),
    do:
      dgettext(
        "errors",
        "Page %{page_number} rendered too large (%{size} bytes, limit %{limit}). Lower the extraction resolution, then reprocess this page.",
        page_number: binding(bindings, :page_number),
        size: binding(bindings, :size),
        limit: binding(bindings, :limit)
      )

  def message({:poppler_not_found, bindings}),
    do:
      dgettext("errors", "Required PDF tool %{command} is not installed",
        command: binding(bindings, :command)
      )

  def message(:soffice_not_found), do: dgettext("errors", "LibreOffice is not installed")

  def message({:source_file_not_found, bindings}),
    do: dgettext("errors", "Source file not found: %{path}", path: binding(bindings, :path))

  def message(:converted_pdf_not_found),
    do: dgettext("errors", "Conversion completed but PDF file not found")

  def message({:conversion_failed, bindings}),
    do:
      dgettext("errors", "Document conversion failed: %{error}", error: binding(bindings, :error))

  def message({:conversion_start_failed, bindings}),
    do:
      dgettext("errors", "Failed to start LibreOffice: %{error}",
        error: binding(bindings, :error)
      )

  def message(:port_died), do: dgettext("errors", "LibreOffice process terminated unexpectedly")

  def message(:conversion_timeout), do: dgettext("errors", "Document conversion timed out")

  def message(:original_upload_missing),
    do: gettext("Original upload unavailable. Re-upload this document to process it again.")

  def message(:already_processing),
    do: gettext("This document still has active processing jobs. Please wait for them to finish.")

  def message(:obsolete_run), do: gettext("The document has changed. Please try again.")

  def message(:invalid_model), do: gettext("Invalid model selection")
  def message(:upload_unreadable), do: dgettext("errors", "Could not read uploaded file")

  def message({:file_too_large, bindings}),
    do:
      dgettext("errors", "File too large (%{size}MB, max %{max}MB)",
        size: binding(bindings, :size),
        max: binding(bindings, :max)
      )

  def message(:empty_question), do: gettext("Please enter a question.")
  def message({:database_error, _}), do: message(:database_error)
  def message(:database_error), do: gettext("Failed to search the document. Please try again.")
  def message(:search_failed), do: gettext("Search is temporarily unavailable. Please try again.")
  def message(:delete_failed), do: gettext("Failed to delete document")
  def message(:reprocess_failed), do: gettext("Failed to reset page for reprocessing")
  def message(:models_unavailable), do: gettext("Failed to fetch models from OpenAI")
  def message(_), do: gettext("Sorry, I encountered an error. Please try again.")

  defp binding(bindings, key) do
    case Keyword.get(bindings, key) do
      value when is_binary(value) or is_number(value) -> value
      value -> message(value)
    end
  end
end
