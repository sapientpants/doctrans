defmodule Doctrans.Processing.SupersedingCrashStub do
  @moduledoc """
  An `OpenAIBehaviour` stub that supersedes a page and then crashes.

  This is the reprocessing race in one call: a page job is mid-flight when the
  user reprocesses the page, and the job's own attempt then fails. It reads the
  page to supersede from `:superseding_crash_page_id`:

      Doctrans.TestEnv.put_env(:superseding_crash_page_id, page.id)

  `Doctrans.Processing.OpenAICrashStub` covers the plain crash; this one exists
  because the guard under test only fires when the generation has moved on
  *since* the run started, which nothing can arrange from outside the run.
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Processing.OpenAIStub

  @impl true
  def extract_markdown(_image_path, _opts) do
    supersede()
    raise "extraction crashed after the page was superseded"
  end

  @impl true
  def translate(_markdown, _source_language, _target_language, _opts) do
    supersede()
    raise "translation crashed after the page was superseded"
  end

  # The race under test is a crash in extraction or translation, not in
  # detection -- which only runs for a document with no source language, and the
  # fixtures set one. Delegating keeps this clause from being dead code with a
  # permanent Dialyzer suppression attached to it.
  @impl true
  def detect_language(markdown, opts), do: OpenAIStub.detect_language(markdown, opts)

  @impl true
  def available?, do: OpenAIStub.available?()

  @impl true
  def list_models, do: OpenAIStub.list_models()

  @impl true
  def chat(messages, opts), do: OpenAIStub.chat(messages, opts)

  @impl true
  def chat_stream(messages, on_delta, opts), do: OpenAIStub.chat_stream(messages, on_delta, opts)

  defp supersede do
    page_id =
      Application.get_env(:doctrans, :superseding_crash_page_id) ||
        raise ArgumentError, "#{inspect(__MODULE__)} needs :superseding_crash_page_id"

    {:ok, _page} = page_id |> Documents.get_page!() |> Pages.reset_page_for_reprocessing()
    :ok
  end
end
