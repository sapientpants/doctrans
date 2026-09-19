defmodule Doctrans.Integration.ProcessingToRetrievalTest do
  @moduledoc """
  One document, from an uploaded source file to a search result that names the
  page it came from.

  The units on this path are covered separately — extraction, translation,
  chunking, the hybrid statement. What nothing covered is the seam: that the
  text extraction wrote is the text translation received, that the text indexing
  embedded is the text the page holds, and that a query for a term only one page
  carries comes back naming *that* page's id, number and image. Every stage runs
  for real here; only the model calls are stubbed, and they are stubbed with
  per-page answers so a result cannot be right by accident.

  Async: `:openai_module` is application-global while the pipeline runs.
  """
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Chunk
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.PageContentStub
  alias Doctrans.Search
  alias Doctrans.TestEnv

  @title "Jahresabschluss 2025"

  setup do
    TestEnv.put_env(:openai_module, PageContentStub)

    document =
      document_fixture(%{
        title: @title,
        original_filename: "jahresabschluss.pdf",
        target_language: "en"
      })

    path = document_source_fixture(document)

    # Oban runs inline in :test, so this one call drives page rendering, both
    # model stages for every page, indexing, and the completion check.
    assert {:ok, _job} = DocumentExtractionJob.enqueue_document(document.id, path)

    document = Documents.get_document_with_pages!(document.id)
    %{document: document, pages: Enum.sort_by(document.pages, & &1.page_number)}
  end

  test "the pipeline carries each page's own text through every stage", %{
    document: document,
    pages: pages
  } do
    assert document.status == "completed"
    assert document.total_pages == 3
    assert Enum.map(pages, & &1.page_number) == [1, 2, 3]

    for page <- pages do
      assert page.extraction_status == "completed"
      assert page.translation_status == "completed"
      assert page.embedding_status == "completed"
      assert page.original_markdown == PageContentStub.source_markdown(page.page_number)
      assert page.translated_markdown == PageContentStub.translated_markdown(page.page_number)
      refute is_nil(page.embedding)
    end
  end

  test "a source term only one page carries retrieves that page", %{
    document: document,
    pages: pages
  } do
    target = Enum.at(pages, 1)

    assert {:ok, [top | rest]} = Search.search(PageContentStub.source_term(2))

    assert top.page_id == target.id
    assert top.document_id == document.id
    assert top.page_number == 2
    assert top.image_path == target.image_path
    assert top.document_title == @title

    # The snippet is drawn from the translation of the page the source term
    # matched, so it names that page rather than the one the term appears in.
    assert top.snippet =~ "Page 2"
    assert top.snippet =~ PageContentStub.translated_term(2)

    # The keyword half found exactly one page; the semantic half ranks the rest
    # of the document behind it, and every one of them is a page of this run.
    assert Enum.sort([top.page_number | Enum.map(rest, & &1.page_number)]) == [1, 2, 3]

    assert MapSet.new([top | rest], & &1.page_id) == MapSet.new(pages, & &1.id)
    refute Enum.any?(rest, &(&1.snippet =~ "Page 2"))
  end

  test "a term that only the translation carries retrieves the same page", %{pages: pages} do
    target = Enum.at(pages, 2)

    assert {:ok, %{results: [top | _], total_count: total, retrieval: :hybrid}} =
             Search.search_with_count(PageContentStub.translated_term(3))

    assert top.page_id == target.id
    assert top.page_number == 3
    assert top.snippet =~ PageContentStub.translated_term(3)
    assert total == 3

    # The source term for the same page is absent from the translation, so the
    # match came from the translated column rather than from the original.
    refute target.translated_markdown =~ PageContentStub.source_term(3)
  end

  test "indexing leaves chunks tied to the page and revision they were cut from", %{
    document: document,
    pages: pages
  } do
    chunks =
      Chunk
      |> where([c], c.page_id in ^Enum.map(pages, & &1.id))
      |> order_by([c], asc: c.page_id, asc: c.chunk_index)
      |> Repo.all()

    assert length(chunks) >= 3
    assert Enum.all?(chunks, &(&1.embedding_status == "completed"))
    assert Enum.all?(chunks, &(not is_nil(&1.embedding)))

    by_page = Enum.group_by(chunks, & &1.page_id)

    for page <- pages do
      page_chunks = Map.fetch!(by_page, page.id)
      assert Enum.map(page_chunks, & &1.chunk_index) == Enum.to_list(0..(length(page_chunks) - 1))
      assert Enum.map_join(page_chunks, "\n\n", & &1.content) == page.original_markdown
    end

    assert {:ok, results} =
             Search.search_in_document(document.id, PageContentStub.source_term(1), limit: 50)

    assert MapSet.new(results, & &1.chunk_id) == MapSet.new(chunks, & &1.id)

    numbers = Map.new(pages, &{&1.id, {&1.page_number, &1.content_revision}})

    for result <- results do
      chunk = Enum.find(chunks, &(&1.id == result.chunk_id))
      assert result.page_id == chunk.page_id
      assert result.original_markdown == chunk.content
      assert {result.page_number, result.content_revision} == Map.fetch!(numbers, result.page_id)
    end
  end
end
