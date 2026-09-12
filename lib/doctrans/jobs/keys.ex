defmodule Doctrans.Jobs.Keys do
  @moduledoc """
  The Oban job argument keys, stated once.

  Callers need these at compile time — they appear in pattern matches and in
  `fragment/1` templates, both of which take literals. Reading them from the job
  module that consumes them made every such caller compile-depend on that job,
  which is what put `Doctrans.Processing.Worker` inside an eleven-module
  compile-connected cycle. This module depends on nothing, so a caller can read a
  key at compile time without joining a cycle.
  """

  @document_id "document_id"
  @page_id "page_id"

  @doc "Argument key holding the document id in `Doctrans.Jobs.DocumentExtractionJob`."
  @spec document_id() :: String.t()
  def document_id, do: @document_id

  @doc "Argument key holding the page id in `Doctrans.Jobs.LlmProcessingJob`."
  @spec page_id() :: String.t()
  def page_id, do: @page_id
end
