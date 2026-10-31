defmodule Doctrans.Processing.SupersedingCrashStub do
  @moduledoc """
  An `OpenAIMock` stub that supersedes a page and then crashes.

  This is the reprocessing race in one call: a page job is mid-flight when the
  user reprocesses the page, and the job's own attempt then fails.

      Doctrans.Processing.SupersedingCrashStub.install(page)

  `Doctrans.Processing.OpenAICrashStub` covers the plain crash; this one exists
  because the guard under test only fires when the generation has moved on
  *since* the run started, which nothing can arrange from outside the run.
  Detection is left to the default stub: it only runs for a document with no
  source language, and the fixtures set one.
  """

  import Mox

  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Processing.OpenAIMock

  @doc """
  Makes extraction and translation supersede `page` and crash, for the running test.
  """
  def install(%{id: page_id}) do
    stub(OpenAIMock, :extract_markdown, fn _image_path, _opts ->
      supersede_then_crash(page_id, "extraction")
    end)

    stub(OpenAIMock, :translate, fn _markdown, _source_language, _target_language, _opts ->
      supersede_then_crash(page_id, "translation")
    end)

    :ok
  end

  # The crash is the scenario, so terminating only with an exception is the
  # correct typing of a correct function.
  @dialyzer {:nowarn_function, supersede_then_crash: 2}
  defp supersede_then_crash(page_id, stage) do
    {:ok, _page} = page_id |> Documents.get_page!() |> Pages.reset_page_for_reprocessing()
    raise "#{stage} crashed after the page was superseded"
  end
end
