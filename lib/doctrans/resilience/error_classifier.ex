defmodule Doctrans.Resilience.ErrorClassifier do
  @moduledoc """
  Classifies errors as retryable or permanent.

  Used to determine whether an operation should be retried or
  immediately marked as failed.

  Every caller hands over a `Doctrans.Errors.reason/0`, the shape
  `Doctrans.Errors.normalize/1` produces: an atom, or a `{tag, bindings}` pair.
  A transport failure arrives as `{:transport_error, [reason: _]}` and an HTTP
  status as `{:http_error, [status: _]}`; the raw exceptions and `{:error, _}`
  wrappers they came from are normalized before they get here.

  ## Classifications

  - `:retryable` - Transient errors that may succeed on retry:
    - Timeouts
    - Connection errors
    - 5xx server errors
    - 429 rate limiting

  - `:permanent` - Errors that won't be fixed by retrying:
    - 4xx client errors (except 429)
    - Validation errors
    - File not found
    - Model not found
    - Extraction limits (page count, page size, image size) and missing tools
    - Poppler timeouts and unparseable `pdfinfo` output: both are properties of
      the file, so a retry only reruns the same work against the same document

  A reason of the shape `{tag, [reason: nested]}` is classified by the nested
  reason, so a wrapper such as `{:pdf_extraction_failed, [reason: nested]}` is
  as retryable as the failure it carries.

  - `:unknown` - Unrecognized errors (treated as retryable by default)
  """

  @type classification :: :retryable | :permanent | :unknown

  @doc """
  Classifies an error as retryable, permanent, or unknown.

  ## Examples

      iex> ErrorClassifier.classify(:timeout)
      :retryable

      iex> ErrorClassifier.classify({:transport_error, [reason: :econnrefused]})
      :retryable

      iex> ErrorClassifier.classify({:http_error, [status: 404]})
      :permanent

      iex> ErrorClassifier.classify({:http_error, [status: 500]})
      :retryable
  """
  @spec classify(Doctrans.Errors.reason() | term()) :: classification()
  def classify(error)

  def classify({:transport_error, _}), do: :retryable
  def classify(:conversion_timeout), do: :retryable
  def classify({:image_unreadable, _}), do: :permanent
  def classify({:validation_failed, _}), do: :permanent
  def classify({:source_file_not_found, _}), do: :permanent
  def classify(:document_not_found), do: :permanent
  def classify(:incomplete_output), do: :permanent
  # A hung endpoint is exactly what the circuit breaker is for, so the total
  # deadline counts as a timeout; a flood, of bytes or of frames, is a broken
  # endpoint, and replaying it only buys the same oversized body again.
  def classify(:inference_deadline_exceeded), do: :retryable
  def classify({:inference_response_too_large, _}), do: :permanent
  def classify({:inference_response_too_fragmented, _}), do: :permanent
  # The endpoint URL is configuration; no attempt changes it.
  def classify(:invalid_endpoint_url), do: :permanent
  def classify(:page_not_found), do: :permanent
  def classify(:soffice_not_found), do: :permanent
  def classify(:document_file_not_found), do: :permanent
  def classify({:unsupported_format, _}), do: :permanent

  # Extraction failures that cannot come out differently on a retry: the
  # document has the page count and page sizes it has, and no number of attempts
  # installs poppler.
  def classify({:pdf_too_many_pages, _}), do: :permanent
  def classify({:pdf_page_too_large, _}), do: :permanent
  def classify({:page_image_too_large, _}), do: :permanent
  def classify({:poppler_not_found, _}), do: :permanent
  def classify(:invalid_page_count), do: :permanent
  def classify(:invalid_page_size), do: :permanent

  # A poppler command that ran out its deadline did so on this document, under
  # a single-slot queue with nothing competing for the renderer. Retrying pins
  # the host's memory for the same deadline again, up to the attempt limit,
  # while every other document waits behind it; the user-facing message already
  # says what to change instead.
  def classify(:pdf_command_timeout), do: :permanent
  def classify(:pdfinfo_timeout), do: :permanent

  # The document's whole budget ran out with pages still to render. Unlike a
  # command that hung, the pages that did render are kept and a retry resumes
  # from them, so another attempt makes progress; the attempt limit bounds it.
  def classify(:pdf_extraction_deadline_exceeded), do: :retryable

  def classify(:timeout), do: :retryable

  # HTTP status codes
  def classify({:http_error, bindings}) when is_list(bindings) do
    case Keyword.fetch!(bindings, :status) do
      429 -> :retryable
      status when status >= 500 and status < 600 -> :retryable
      status when status >= 400 and status < 500 -> :permanent
      _ -> :unknown
    end
  end

  # A wrapper such as `{:pdf_extraction_failed, [reason: nested]}` says where
  # the failure happened; the nested reason says what it was, and that is what
  # decides whether a retry can change the answer.
  def classify({tag, bindings}) when is_atom(tag) and is_list(bindings) do
    case Keyword.fetch(bindings, :reason) do
      {:ok, nested} -> classify(nested)
      :error -> :unknown
    end
  end

  # Catch-all
  def classify(_), do: :unknown

  @doc """
  Returns true if the error is classified as retryable.

  Unknown errors are treated as retryable by default.

  ## Examples

      iex> ErrorClassifier.retryable?(:timeout)
      true

      iex> ErrorClassifier.retryable?({:http_error, [status: 404]})
      false
  """
  @spec retryable?(Doctrans.Errors.reason() | term()) :: boolean()
  def retryable?(error) do
    case classify(error) do
      :retryable -> true
      :unknown -> true
      :permanent -> false
    end
  end
end
