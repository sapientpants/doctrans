defmodule Doctrans.Jobs.Keys do
  @moduledoc """
  The Oban job argument keys, stated once.

  Callers need these at compile time — they appear in pattern matches and in
  `fragment/1` templates, both of which take literals. Reading a key from the job
  module that consumes it makes the caller compile-depend on that job, and on
  everything the job reaches; that is what the `xref-cycles` gate catches.

  **This module must depend on nothing**, so that a caller can read a key at
  compile time without joining a compile cycle. See PLAN.md G16.
  """

  @document_id "document_id"
  @page_id "page_id"

  @doc "Argument key holding the document id in `DocumentExtractionJob` and `RunCleanupJob`."
  @spec document_id() :: String.t()
  def document_id, do: @document_id

  @doc "Argument key holding the page id in `LlmProcessingJob`."
  @spec page_id() :: String.t()
  def page_id, do: @page_id
end
