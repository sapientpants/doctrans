defmodule Doctrans.Documents.PageLifecycleLogTest do
  @moduledoc """
  `async: false`: the suite runs Logger at `:warning`, which drops an info line
  before any capture handler sees it, so the refusal log is read at `:info`
  under a temporarily lowered global level.
  """
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.PageLifecycle

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    document = document_fixture(%{status: "processing", total_pages: 1})
    %{document: document, page: page_fixture(document)}
  end

  test "a refused transition says why in the log", %{document: document, page: page} do
    _ = Documents.delete_pages(document.id)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        {:error, :obsolete_run} = PageLifecycle.begin(page, :extraction)
      end)

    assert log =~ "Refused begin for page #{page.id}: obsolete_run"
  end
end
