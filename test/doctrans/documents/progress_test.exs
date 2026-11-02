defmodule Doctrans.Documents.ProgressTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.{Document, Progress}

  setup do
    %{unloaded_pages: %Document{}.pages}
  end

  test "empty pages and unknown or zero totals have zero progress" do
    assert Progress.calculate([], 2) == 0.0
    assert Progress.calculate([page("completed", "completed")], nil) == 0.0
    assert Progress.calculate([page("completed", "completed")], 0) == 0.0
  end

  test "only completed extraction and translation steps count" do
    pages = [
      page("completed", "completed"),
      page("completed", "processing"),
      page("error", "pending")
    ]

    assert Progress.calculate(pages, 3) == 50.0
    assert Progress.calculate([page("pending", "pending")], 1) == 0.0
    assert Progress.calculate([page("completed", "completed")], 1) == 100.0
  end

  test "the document total includes pages that have not been created yet" do
    assert Progress.calculate([page("completed", "completed")], 4) == 25.0
  end

  test "from_counts/3 is the definition calculate/2 delegates to" do
    pages = [page("completed", "completed"), page("completed", "processing")]

    assert Progress.from_counts(2, 1, 3) == Progress.calculate(pages, 3)
    assert Progress.from_counts(2, 1, nil) == 0.0
    assert Progress.from_counts(2, 1, 0) == 0.0
    assert Progress.from_counts(0, 0, 4) == 0.0
  end

  test "unloaded associations are rejected instead of triggering database queries", %{
    unloaded_pages: pages
  } do
    assert_raise FunctionClauseError, fn ->
      Progress.calculate(pages, 1)
    end
  end

  defp page(extraction, translation) do
    %{extraction_status: extraction, translation_status: translation}
  end
end
