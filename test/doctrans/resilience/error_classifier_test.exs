defmodule Doctrans.Resilience.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Doctrans.Resilience.ErrorClassifier

  describe "classify/1" do
    test "classifies timeout atom as retryable" do
      assert ErrorClassifier.classify(:timeout) == :retryable
    end

    test "classifies normalized transport errors as retryable, whatever the reason" do
      for reason <- [:timeout, :econnrefused, :econnreset, :closed, :nxdomain, :ehostunreach] do
        assert ErrorClassifier.classify({:transport_error, [reason: reason]}) == :retryable
      end

      # The shape `Doctrans.Errors.normalize/1` gives a raised transport error.
      normalized = Doctrans.Errors.normalize(%Req.TransportError{reason: :other})
      assert ErrorClassifier.classify(normalized) == :retryable
    end

    test "classifies conversion timeout as retryable" do
      assert ErrorClassifier.classify(:conversion_timeout) == :retryable
    end

    test "classifies pipeline stage failures as permanent" do
      assert ErrorClassifier.classify({:validation_failed, [changeset: %Ecto.Changeset{}]}) ==
               :permanent

      assert ErrorClassifier.classify({:source_file_not_found, [path: "/tmp/missing.docx"]}) ==
               :permanent

      assert ErrorClassifier.classify(:document_not_found) == :permanent
      assert ErrorClassifier.classify(:document_file_not_found) == :permanent
      assert ErrorClassifier.classify(:page_not_found) == :permanent
      assert ErrorClassifier.classify(:soffice_not_found) == :permanent
      assert ErrorClassifier.classify({:unsupported_format, [format: ".txt"]}) == :permanent
    end

    test "classifies extraction limits and missing tools as permanent" do
      assert ErrorClassifier.classify({:pdf_too_many_pages, [pages: 9999, limit: 1000]}) ==
               :permanent

      assert ErrorClassifier.classify({:pdf_page_too_large, [page_number: 1]}) == :permanent

      assert ErrorClassifier.classify(
               {:page_image_too_large, [page_number: 1, size: 1, limit: 1]}
             ) ==
               :permanent

      assert ErrorClassifier.classify({:poppler_not_found, [command: "pdftoppm"]}) == :permanent
    end

    test "classifies a wrapped reason by the reason it carries" do
      assert ErrorClassifier.classify(
               {:pdf_extraction_failed, [reason: {:pdf_too_many_pages, [pages: 9, limit: 1]}]}
             ) == :permanent

      assert ErrorClassifier.classify({:pdf_extraction_failed, [reason: :pdf_command_timeout]}) ==
               :unknown

      assert ErrorClassifier.classify({:pdf_extraction_failed, [reason: :timeout]}) == :retryable

      # Nesting is followed all the way down.
      assert ErrorClassifier.classify(
               {:outer, [reason: {:inner, [reason: {:http_error, [status: 404]}]}]}
             ) == :permanent

      # A pair without a nested reason says nothing about retryability.
      assert ErrorClassifier.classify({:pdf_command_failed, [exit_status: 1]}) == :unknown
    end

    test "classifies HTTP 5xx errors as retryable" do
      assert ErrorClassifier.classify({:http_error, [status: 500]}) == :retryable
      assert ErrorClassifier.classify({:http_error, [status: 502]}) == :retryable
      assert ErrorClassifier.classify({:http_error, [status: 503]}) == :retryable
      assert ErrorClassifier.classify({:http_error, [status: 599]}) == :retryable
    end

    test "classifies HTTP 429 as retryable" do
      assert ErrorClassifier.classify({:http_error, [status: 429]}) == :retryable
    end

    test "classifies HTTP 4xx errors as permanent" do
      assert ErrorClassifier.classify({:http_error, [status: 400]}) == :permanent
      assert ErrorClassifier.classify({:http_error, [status: 404]}) == :permanent
      assert ErrorClassifier.classify({:http_error, [status: 422]}) == :permanent
    end

    test "classifies an unreadable page image as permanent, whatever the file error" do
      for reason <- [:enoent, :eacces, :enotdir] do
        assert ErrorClassifier.classify({:image_unreadable, [reason: reason]}) == :permanent
      end
    end

    test "returns unknown for unrecognized errors" do
      assert ErrorClassifier.classify(:some_random_error) == :unknown

      assert ErrorClassifier.classify({:operation_failed, [reason: {:complex, :error}]}) ==
               :unknown

      assert ErrorClassifier.classify("some random message") == :unknown
    end
  end

  describe "retryable?/1" do
    test "returns true for retryable errors" do
      assert ErrorClassifier.retryable?(:timeout) == true
      assert ErrorClassifier.retryable?({:http_error, [status: 500]}) == true
    end

    test "returns true for unknown errors (default to retry)" do
      assert ErrorClassifier.retryable?(:some_unknown) == true
    end

    test "returns false for permanent errors" do
      assert ErrorClassifier.retryable?({:http_error, [status: 404]}) == false
      assert ErrorClassifier.retryable?({:image_unreadable, [reason: :enoent]}) == false
    end
  end
end
