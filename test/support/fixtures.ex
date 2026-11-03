defmodule Doctrans.Fixtures do
  @moduledoc """
  Test fixtures for creating documents and pages.

  The page fixtures come in two kinds. `page_fixture/2`, `completed_page_fixture/2`
  and `searchable_page_fixture/2` go through the `Documents` API, so they produce
  what the pipeline would. `indexed_page_fixture/2` writes through `Repo`, because
  that API takes no embedding and a page that search can rank needs one in the
  same write as its text.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Doctrans.Documents
  alias Doctrans.Documents.{Layout, Page}
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.{OpenAIMock, PageContentStub, Run}
  alias Doctrans.Repo
  alias Doctrans.Search.Embedding

  @doc """
  Creates a document with valid attributes.
  """
  def document_fixture(attrs \\ %{}) do
    {:ok, document} =
      attrs
      |> Enum.into(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "de",
        status: "uploading"
      })
      |> Documents.create_document()

    document
  end

  @doc """
  Creates a document with pages.
  """
  def document_with_pages_fixture(attrs \\ %{}, page_count \\ 3) do
    document = document_fixture(Map.merge(%{total_pages: page_count}, attrs))

    for page_num <- 1..page_count do
      {:ok, _page} =
        Documents.create_page(document, %{
          page_number: page_num,
          image_path: "documents/#{document.id}/pages/page_#{page_num}.png"
        })
    end

    Documents.get_document_with_pages(document.id)
  end

  @doc """
  Creates a page for a document.
  """
  def page_fixture(document, attrs \\ %{}) do
    {:ok, page} =
      Documents.create_page(
        document,
        Enum.into(attrs, %{
          page_number: 1,
          image_path: "documents/#{document.id}/pages/page_1.png"
        })
      )

    page
  end

  @doc """
  A deterministic embedding of the stored width, every component `value`.

  `Doctrans.Search.EmbeddingStub` embeds every query as `dimensions` components
  of `0.1`, so a page carrying `fake_embedding()` is a perfect semantic match for
  any query, and one carrying `fake_embedding(-0.1)` points the opposite way and
  never clears the similarity floor.
  """
  def fake_embedding(value \\ 0.1) do
    Pgvector.new(List.duplicate(value, Embedding.dimensions()))
  end

  @doc """
  Inserts a fully processed page -- extracted, translated and indexed -- into
  `document`, and returns it.

  `attrs` override any `Page` field. The embedding defaults to `fake_embedding/1`,
  the page number to 1, and the text names the document and page so a result can
  be told apart from its neighbours.
  """
  def indexed_page_fixture(document, attrs \\ %{}) do
    page_number = Map.get(attrs, :page_number, 1)

    page = %Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: page_number,
      image_path: "documents/#{document.id}/pages/page_#{page_number}.png",
      original_markdown: "Content in document #{document.title} page #{page_number}",
      translated_markdown: "Translated content page #{page_number}",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: fake_embedding()
    }

    Repo.insert!(struct!(page, attrs))
  end

  @doc """
  One extracted page in a completed document of its own: the smallest thing
  global search is allowed to find. Returns the page.

  The page carries no embedding unless `attrs` give one, so only the keyword
  half of a search can find it. `attrs` may also carry `:title` for the document
  and `:page_number` for the page.
  """
  def searchable_page_fixture(text, attrs \\ %{}) do
    {title, attrs} = Map.pop(attrs, :title, "Searchable Doc")
    {embedding, attrs} = Map.pop(attrs, :embedding)
    document = document_fixture(%{status: "completed", title: title})

    {:ok, page} =
      document
      |> page_fixture(attrs)
      |> Documents.update_page_extraction(%{
        extraction_status: "completed",
        original_markdown: text
      })

    if embedding do
      page |> Ecto.Changeset.change(embedding: embedding) |> Repo.update!()
    else
      page
    end
  end

  @doc """
  Creates a completed, single-page document whose page carries an embedding, so
  the chat opens with a usable context.
  """
  def completed_document_with_embedding_fixture(attrs \\ %{}) do
    document = document_fixture(Enum.into(attrs, %{status: "completed", total_pages: 1}))

    indexed_page_fixture(document, %{
      original_markdown: "Testinhalt für Chat",
      translated_markdown: "Test content for chat"
    })

    document
  end

  @doc """
  Writes a placeholder source file where a processing run looks for the original.

  `Doctrans.Processing.Run.source_path/1` is the only path the extraction job
  reads from once a run exists, so a test that drives extraction has to put a
  file there. Returns that path and removes the document's upload directory when
  the test exits.
  """
  def document_source_fixture(document, contents \\ "%PDF-1.4\n") do
    path = Run.source_path(document)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(Layout.document_dir(document.id)) end)
    path
  end

  @doc """
  Runs a three-page document through the whole pipeline -- page rendering, both
  model stages for every page, indexing -- and returns it with its pages in
  order and the path of its retained source.

  The models are `Doctrans.Processing.PageContentStub`, installed here on
  `OpenAIMock`, so each page ends up with a source term and a translated term
  no other page carries. Oban runs inline in `:test`, so the one `enqueue` call
  drives everything. A caller that wants to observe the run through the
  embedding mock -- the inputs it was asked to embed, say -- installs that
  probe before calling this; a stub on `OpenAIMock` installed beforehand is
  replaced here, so it has to be installed afterwards.

  Raises if the run did not leave the document `completed`, so a pipeline that
  stops short is reported here rather than by whichever later assertion first
  misses the pages it expected.
  """
  def processed_document_fixture(attrs \\ %{}) do
    Mox.stub_with(OpenAIMock, PageContentStub)

    document =
      document_fixture(
        Enum.into(attrs, %{
          title: "Jahresabschluss 2025",
          original_filename: "jahresabschluss.pdf",
          target_language: "en"
        })
      )

    source_path = document_source_fixture(document)
    {:ok, _job} = DocumentExtractionJob.enqueue_document(document.id, source_path)

    document = Documents.get_document_with_pages(document.id)

    if document.status != "completed" do
      raise "processed_document_fixture: the pipeline left document #{document.id} " <>
              "in status #{inspect(document.status)} rather than \"completed\""
    end

    %{
      document: document,
      pages: Enum.sort_by(document.pages, & &1.page_number),
      source_path: source_path
    }
  end

  @doc """
  Creates a completed page (extraction and translation done).
  """
  def completed_page_fixture(document, attrs \\ %{}) do
    page = page_fixture(document, attrs)

    {:ok, page} =
      Documents.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: "# Original Content\n\nSome text here."
      })

    {:ok, page} =
      Documents.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated Content\n\nSome translated text."
      })

    page
  end
end
