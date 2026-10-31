defmodule DoctransWeb.ErrorMessages do
  @moduledoc """
  Translates domain error reasons in the calling web process's locale.

  Every string here lives in the `errors` gettext domain. A reason the catalog
  does not name renders as a neutral generic message, written to read the same
  in a flash, in an upload row, and nested inside another message such as
  "Page 3 extraction failed: ...". A surface that speaks in its own voice -- the
  chat panel answers in the first person -- supplies its own fallback through
  `message/2` rather than teaching the catalog a second generic.
  """
  use Gettext, backend: DoctransWeb.Gettext

  @doc "Renders `reason`, or the neutral generic message when it has no entry."
  @spec message(term()) :: String.t()
  def message(reason), do: lookup(reason) || generic()

  @doc "Renders `reason`, or `fallback` when it has no entry of its own."
  @spec message(term(), String.t()) :: String.t()
  def message(reason, fallback) when is_binary(fallback), do: lookup(reason) || fallback

  defp generic, do: dgettext("errors", "An unexpected error occurred. Please try again.")

  defp lookup(:query_too_short), do: dgettext("errors", "Query too short")

  defp lookup({:query_too_long, bindings}),
    do: dgettext("errors", "Query too long (max %{max} characters)", max: binding(bindings, :max))

  defp lookup(:invalid_query), do: dgettext("errors", "Search query must be a string")

  defp lookup({:unsupported_language, bindings}),
    do:
      dgettext("errors", "Unsupported language: %{language}",
        language: binding(bindings, :language)
      )

  defp lookup(:invalid_language), do: dgettext("errors", "Language code must be a string")

  defp lookup(:file_content_mismatch),
    do: dgettext("errors", "File content does not match its extension")

  defp lookup(:file_too_small), do: dgettext("errors", "File is too small to be a valid document")

  defp lookup(:file_unreadable), do: dgettext("errors", "Could not read file for validation")

  defp lookup(:invalid_file_arguments),
    do: dgettext("errors", "File path and extension must be strings")

  defp lookup({:missing_required_fields, bindings}),
    do:
      dgettext("errors", "Missing required fields: %{fields}", fields: binding(bindings, :fields))

  defp lookup(:empty_title), do: dgettext("errors", "Title cannot be empty")

  defp lookup(:invalid_title), do: dgettext("errors", "Title is required and must be a string")

  defp lookup(:invalid_target_language),
    do: dgettext("errors", "Target language is required and must be a string")

  defp lookup(:invalid_source_language),
    do: dgettext("errors", "Source language is required and must be a string")

  defp lookup(:document_not_found), do: dgettext("errors", "Document not found")

  defp lookup(:incomplete_output),
    do:
      dgettext(
        "errors",
        "The model did not return complete final text. Use a model with a larger output budget or split the page into smaller sections, then reprocess. The provider must return finish_reason=stop."
      )

  defp lookup(:inference_deadline_exceeded),
    do:
      dgettext(
        "errors",
        "The model server ran out of time and the request was stopped. Check that it is running and responsive, then reprocess this page."
      )

  defp lookup({:inference_response_too_large, bindings}),
    do:
      dgettext(
        "errors",
        "The model server's answer went past the %{limit} byte limit and was stopped before it was read. Check the configured model and endpoint, then try again.",
        limit: binding(bindings, :limit)
      )

  defp lookup(:page_not_found), do: dgettext("errors", "Page not found")

  defp lookup({:page_extraction_failed, bindings}),
    do:
      dgettext("errors", "Page %{page_number} extraction failed: %{reason}",
        page_number: binding(bindings, :page_number),
        reason: binding(bindings, :reason)
      )

  defp lookup({:page_translation_failed, bindings}),
    do:
      dgettext("errors", "Page %{page_number} translation failed: %{reason}",
        page_number: binding(bindings, :page_number),
        reason: binding(bindings, :reason)
      )

  defp lookup({:pages_failed, bindings}),
    do:
      dgettext(
        "errors",
        "Processing failed on page(s) %{page_numbers}. Reprocess those pages to finish this document.",
        page_numbers: binding(bindings, :page_numbers)
      )

  defp lookup({:unsupported_format, bindings}),
    do:
      dgettext("errors", "Unsupported file format: %{format}", format: binding(bindings, :format))

  # A file with no extension at all, where naming the format would say nothing.
  defp lookup(:unsupported_format),
    do: dgettext("errors", "Only PDF, Word, OpenDocument, and RTF documents are accepted")

  defp lookup({:pdf_extraction_failed, bindings}),
    do: dgettext("errors", "PDF extraction failed: %{reason}", reason: binding(bindings, :reason))

  defp lookup({:pdf_command_failed, bindings}),
    do: dgettext("errors", "PDF extraction failed: %{error}", error: binding(bindings, :error))

  defp lookup(:page_image_not_found),
    do: dgettext("errors", "Page image not found after extraction")

  defp lookup(:invalid_page_count),
    do: dgettext("errors", "Could not parse page count from pdfinfo output")

  defp lookup({:pdfinfo_failed, bindings}),
    do: dgettext("errors", "pdfinfo failed: %{error}", error: binding(bindings, :error))

  defp lookup(:pdf_command_timeout),
    do:
      dgettext(
        "errors",
        "PDF rendering timed out. Lower the extraction resolution or split the document, then try again."
      )

  defp lookup(:pdfinfo_timeout),
    do:
      dgettext(
        "errors",
        "Reading the PDF timed out before extraction started. The file may be damaged."
      )

  defp lookup(:pdf_extraction_deadline_exceeded),
    do:
      dgettext(
        "errors",
        "Extraction ran out of time for this document. Finished pages were kept; reprocess it to continue."
      )

  defp lookup({:pdf_too_many_pages, bindings}),
    do:
      dgettext(
        "errors",
        "This PDF has %{pages} pages, above the limit of %{limit}. Split it into smaller documents before uploading.",
        pages: binding(bindings, :pages),
        limit: binding(bindings, :limit)
      )

  defp lookup({:pdf_page_too_large, bindings}),
    do:
      dgettext(
        "errors",
        "This PDF's pages are %{width}x%{height} pixels at %{dpi} DPI, above the limit of %{limit} pixels. Lower the extraction resolution, then try again.",
        width: binding(bindings, :width),
        height: binding(bindings, :height),
        dpi: binding(bindings, :dpi),
        limit: binding(bindings, :limit)
      )

  defp lookup({:page_image_too_large, bindings}),
    do:
      dgettext(
        "errors",
        "Page %{page_number} rendered too large (%{size} bytes, limit %{limit}). Lower the extraction resolution, then reprocess this page.",
        page_number: binding(bindings, :page_number),
        size: binding(bindings, :size),
        limit: binding(bindings, :limit)
      )

  defp lookup({:poppler_not_found, bindings}),
    do:
      dgettext("errors", "Required PDF tool %{command} is not installed",
        command: binding(bindings, :command)
      )

  defp lookup(:soffice_not_found), do: dgettext("errors", "LibreOffice is not installed")

  defp lookup({:source_file_not_found, bindings}),
    do: dgettext("errors", "Source file not found: %{path}", path: binding(bindings, :path))

  defp lookup(:converted_pdf_not_found),
    do: dgettext("errors", "Conversion completed but PDF file not found")

  defp lookup({:conversion_failed, bindings}),
    do:
      dgettext("errors", "Document conversion failed: %{error}", error: binding(bindings, :error))

  defp lookup({:conversion_start_failed, bindings}),
    do:
      dgettext("errors", "Failed to start LibreOffice: %{error}",
        error: binding(bindings, :error)
      )

  defp lookup(:port_died), do: dgettext("errors", "LibreOffice process terminated unexpectedly")

  defp lookup(:conversion_timeout), do: dgettext("errors", "Document conversion timed out")

  defp lookup(:original_upload_missing),
    do:
      dgettext(
        "errors",
        "Original upload unavailable. Re-upload this document to process it again."
      )

  defp lookup(:already_processing),
    do:
      dgettext(
        "errors",
        "This document still has active processing jobs. Please wait for them to finish."
      )

  defp lookup(:obsolete_run),
    do: dgettext("errors", "The document has changed. Please try again.")

  defp lookup(:not_cancellable),
    do:
      dgettext(
        "errors",
        "This document has already finished processing, so there is nothing left to stop."
      )

  defp lookup(:nothing_to_retry),
    do:
      dgettext(
        "errors",
        "No page of this document is waiting to be retried. Reload the page to see its current state."
      )

  # Upload readiness (`Doctrans.Config.Readiness`). Each one names the setting to
  # change and what stays broken until it is changed, because these are reported
  # before anything has been uploaded: the user is deciding, not recovering.
  # `%{destination}` is a host or a redacted URL from `Doctrans.Config.Inference`
  # and never carries a credential.
  defp lookup({:inference_unavailable, bindings}),
    do:
      dgettext(
        "errors",
        "The model server at %{destination} is not answering. Start it before uploading, or documents will wait in the queue until it is running.",
        destination: binding(bindings, :destination)
      )

  defp lookup({:extraction_model_unavailable, bindings}),
    do:
      dgettext(
        "errors",
        "The extraction model %{model} is not available on %{destination}. Load it there, or set the extraction model to one that server offers.",
        model: binding(bindings, :model),
        destination: binding(bindings, :destination)
      )

  defp lookup({:translation_model_unavailable, bindings}),
    do:
      dgettext(
        "errors",
        "The translation model %{model} is not available on %{destination}. Load it there, or set the translation model to one that server offers.",
        model: binding(bindings, :model),
        destination: binding(bindings, :destination)
      )

  # Search is the only casualty of a broken embedding path, and saying so is what
  # keeps this from reading as a reason to cancel the upload.
  defp lookup({:embedding_model_unavailable, bindings}),
    do:
      dgettext(
        "errors",
        "The embedding model %{model} is not available on %{destination}. Documents will still translate, but they cannot be searched until it is loaded there or the embedding model names one that server offers.",
        model: binding(bindings, :model),
        destination: binding(bindings, :destination)
      )

  defp lookup({:embedding_unavailable, bindings}),
    do:
      dgettext(
        "errors",
        "The embedding server at %{destination} is not answering. Documents will still translate, but they cannot be searched until it is running.",
        destination: binding(bindings, :destination)
      )

  defp lookup({:embedding_dimensions_too_small, bindings}),
    do:
      dgettext(
        "errors",
        "The embedding model %{model} returns %{actual} dimensions, but %{expected} are required. Choose an embedding model with at least %{expected} dimensions; until then documents translate but cannot be searched.",
        model: binding(bindings, :model),
        actual: binding(bindings, :actual),
        expected: binding(bindings, :expected)
      )

  defp lookup(:invalid_model), do: dgettext("errors", "Invalid model selection")
  defp lookup(:upload_unreadable), do: dgettext("errors", "Could not read uploaded file")

  defp lookup(:upload_store_failed),
    do: dgettext("errors", "Could not store the uploaded file")

  defp lookup(:upload_start_failed),
    do: dgettext("errors", "Could not start processing for this document")

  # The upload list's own fallback: it names the file's fate, where the generic
  # message could only say that something failed.
  defp lookup(:upload_failed),
    do: dgettext("errors", "This file could not be uploaded. Please try again.")

  # The changeset is dropped deliberately: a per-file upload message says the save
  # failed, never which column the database objected to.
  defp lookup({:validation_failed, _bindings}),
    do: dgettext("errors", "The document could not be saved")

  defp lookup({:file_too_large, bindings}),
    do:
      dgettext("errors", "File too large (%{size}MB, max %{max}MB)",
        size: binding(bindings, :size),
        max: binding(bindings, :max)
      )

  defp lookup(:empty_question), do: dgettext("errors", "Please enter a question.")
  defp lookup({:database_error, _}), do: lookup(:database_error)

  defp lookup(:database_error),
    do: dgettext("errors", "Failed to search the document. Please try again.")

  defp lookup(:search_failed),
    do: dgettext("errors", "Search is temporarily unavailable. Please try again.")

  defp lookup({:retrieval_unavailable, _}), do: lookup(:retrieval_unavailable)

  defp lookup(:retrieval_unavailable),
    do: dgettext("errors", "Document search is temporarily unavailable. Please try again.")

  defp lookup(:delete_failed), do: dgettext("errors", "Failed to delete document")
  defp lookup(:reprocess_failed), do: dgettext("errors", "Failed to reset page for reprocessing")

  defp lookup(:models_unavailable),
    do: dgettext("errors", "Could not fetch the list of models from the model server")

  defp lookup(_), do: nil

  # A binding that is itself a reason is rendered through `message/1`, so a
  # nested reason without an entry reads as the same neutral text as a bare one.
  defp binding(bindings, key) do
    case Keyword.get(bindings, key) do
      value when is_binary(value) or is_number(value) -> value
      value -> message(value)
    end
  end
end
