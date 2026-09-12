defmodule Doctrans.Documents.SummaryTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.{Document, Summary}

  test "uses page one for the thumbnail regardless of row order" do
    document = %Document{id: Ecto.UUID.generate(), total_pages: 2}
    pages = [page(2, "second.png"), page(1, "first.png")]

    summary = Summary.new(document, pages)

    assert summary.document == document
    assert summary.id == document.id
    assert summary.thumbnail_path == "first.png"
    assert summary.progress == 50.0
  end

  test "does not substitute a later page when page one is absent" do
    summary = Summary.new(%Document{total_pages: 2}, [page(2, "second.png")])
    assert summary.thumbnail_path == nil
  end

  test "lists the failed pages in row order" do
    document = %Document{id: Ecto.UUID.generate(), total_pages: 3}

    pages = [
      %{page(1, "first.png") | extraction_status: "error"},
      %{page(2, "second.png") | translation_status: "completed"},
      %{page(3, "third.png") | translation_status: "error"}
    ]

    assert Summary.new(document, pages).failed_pages == [1, 3]
  end

  test "has no failed pages while work is still outstanding" do
    document = %Document{id: Ecto.UUID.generate(), total_pages: 2}
    assert Summary.new(document, [page(1, "first.png"), page(2, "second.png")]).failed_pages == []
  end

  defp page(number, image_path) do
    %{
      page_number: number,
      image_path: image_path,
      extraction_status: "completed",
      translation_status: "pending"
    }
  end
end
