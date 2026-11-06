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
  alias Doctrans.Documents.{Document, Layout, Lifecycle, Page}
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.{OpenAIMock, PageContentStub, Run}
  alias Doctrans.Repo
  alias Doctrans.Search.Embedding

  @doc """
  Creates a document in `status`, reached the way production reaches it.

  The row is created `uploading`, then walked through the real transitions of
  `Doctrans.Documents.Lifecycle`: a run is requeued, extraction and processing
  begin, and `error` or `cancelled` come from `fail/2` (with `error_message`
  as the reason) or `cancel/1`. Every document past `uploading` therefore
  holds a run. The walk happens inside one bare `Repo.transaction/1`, which
  drops the announcements the transitions queue with `Repo.after_commit/1`,
  so no test receives the fixture's own broadcasts; `total_pages` is applied
  after it, because requeueing clears the count.

  `completed` is the one shortcut: settling needs pages, and callers create
  their own, so the status is written through `Document.status_changeset/3`
  (the changeset the lifecycle uses) after the walk reaches `processing`. A
  test that needs a document settled for real uses
  `processed_document_fixture/1`.

  An `error_message` with any status but `error` raises: no transition leaves
  a diagnostic on a document that is not failed.
  """
  def document_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "en",
        source_language: "de"
      })

    {status, attrs} = Map.pop(attrs, :status, "uploading")
    {error_message, attrs} = Map.pop(attrs, :error_message)
    {total_pages, attrs} = Map.pop(attrs, :total_pages)

    if error_message && status != "error" do
      raise ArgumentError,
            "a #{status} document cannot carry a diagnostic; only `fail/2` writes one"
    end

    {:ok, document} = Documents.create_document(attrs)

    {:ok, document} =
      Repo.transaction(fn ->
        document
        |> walk(status, error_message)
        |> with_total_pages(total_pages)
      end)

    document
  end

  @doc """
  A row from before runs existed: a status past `uploading` with no run, which
  no transition produces. Written structurally for exactly that reason, so a
  test of the legacy branches says what it is testing.
  """
  def legacy_document_fixture(attrs \\ %{}) do
    {status, attrs} = Map.pop(attrs, :status, "queued")
    {error_message, attrs} = Map.pop(attrs, :error_message)
    {total_pages, attrs} = Map.pop(attrs, :total_pages)

    document = document_fixture(attrs)

    document
    |> Document.status_changeset(status, error_message)
    |> Ecto.Changeset.change(total_pages: total_pages)
    |> Repo.update!()
  end

  defp walk(document, "uploading", _reason), do: document

  defp walk(document, "queued", _reason),
    do: transition(Lifecycle.requeue(document, Run.new_attrs()))

  defp walk(document, "extracting", _reason),
    do: document |> walk("queued", nil) |> Lifecycle.begin_extraction() |> transition()

  defp walk(document, "processing", _reason) do
    :ok = document |> walk("extracting", nil) |> Lifecycle.begin_processing()
    Documents.get_document!(document.id)
  end

  defp walk(document, "completed", _reason) do
    document
    |> walk("processing", nil)
    |> Document.status_changeset("completed")
    |> Repo.update!()
  end

  defp walk(document, "error", reason),
    do: document |> walk("processing", nil) |> Lifecycle.fail(reason) |> transition()

  defp walk(document, "cancelled", _reason),
    do: document |> walk("processing", nil) |> Lifecycle.cancel() |> transition()

  defp transition({:ok, document}), do: document

  defp with_total_pages(document, nil), do: document

  defp with_total_pages(document, total_pages) do
    {:ok, counted} = Documents.set_total_pages(document, total_pages)
    counted
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
