defmodule Doctrans.Fixtures do
  @moduledoc """
  Test fixtures for creating documents and pages.

  Every page fixture -- `page_fixture/2`, `completed_page_fixture/2`,
  `searchable_page_fixture/2`, `indexed_page_fixture/2` -- goes through the
  `Documents` API and the real transitions of `Doctrans.Documents.PageLifecycle`,
  so it produces what the pipeline would; like `document_fixture/1` they walk
  inside a bare `Repo.transaction/1`, which drops the announcements the
  transitions queue, so no test receives a fixture's own broadcasts.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Layout, Lifecycle, PageLifecycle}
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
  Creates a page for a document, with its stages where `attrs` say.

  `:extraction_status`, `:translation_status` and `:embedding_status` are
  reached through the real transitions of `Doctrans.Documents.PageLifecycle`,
  silently: `"processing"` begins the stage, `"error"` fails it, and
  `"completed"` completes it with the stage's product -- `:original_markdown`
  or `:translated_markdown` (`""` when not given) and `:extraction_model` or
  `:translation_model` for the content stages, `:embedding` (`fake_embedding/0`
  when not given) for the embedding stage. A product given without a status
  completes its stage, since only completion produces one. Everything else
  goes to the page row.
  """
  def page_fixture(document, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {extraction, attrs} = pop_stage(attrs, :extraction)
    {translation, attrs} = pop_stage(attrs, :translation)
    {embedding, attrs} = pop_stage(attrs, :embedding)

    {:ok, page} =
      Repo.transaction(fn ->
        {:ok, page} =
          Documents.create_page(
            document,
            Enum.into(attrs, %{
              page_number: 1,
              image_path: "documents/#{document.id}/pages/page_1.png"
            })
          )

        page
        |> walk_stage(:extraction, extraction)
        |> walk_stage(:translation, translation)
        |> walk_stage(:embedding, embedding)
      end)

    page
  end

  # The embedding stage names no model, so its model key is `nil` and pops
  # nothing.
  defp pop_stage(attrs, stage) do
    fields = PageLifecycle.fields(stage)
    {status, attrs} = Map.pop(attrs, fields.status)
    {product, attrs} = Map.pop(attrs, fields.product)
    {model, attrs} = Map.pop(attrs, fields[:model])
    status = status || if(product != nil, do: "completed", else: "pending")
    {{status, product, model}, attrs}
  end

  defp walk_stage(page, _stage, {"pending", nil, nil}), do: page

  defp walk_stage(page, stage, {"processing", nil, nil}),
    do: page |> PageLifecycle.begin(stage) |> transition()

  defp walk_stage(page, stage, {"error", nil, nil}),
    do: page |> PageLifecycle.fail(stage) |> transition()

  # A stage that failed after an earlier attempt produced something: complete
  # it with that product, then fail it, as a retried job would leave it.
  defp walk_stage(page, stage, {"error", markdown, model}) do
    page
    |> walk_stage(stage, {"completed", markdown, model})
    |> walk_stage(stage, {"error", nil, nil})
  end

  defp walk_stage(page, :embedding, {"completed", embedding, nil}) do
    page
    |> PageLifecycle.complete(:embedding, %{embedding: embedding || fake_embedding()})
    |> transition()
  end

  defp walk_stage(page, stage, {"completed", markdown, model}) do
    page
    |> PageLifecycle.complete(stage, %{markdown: markdown || "", model: model})
    |> transition()
  end

  defp walk_stage(_page, stage, {status, markdown, _model}) do
    raise ArgumentError,
          "page_fixture: no transition leaves #{stage} #{inspect(status)} with #{inspect(markdown)}"
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
  Creates a fully processed page -- extracted, translated and indexed -- in
  `document`, through the real transitions, and returns it.

  `attrs` are `page_fixture/2`'s. The embedding defaults to `fake_embedding/1`,
  the page number to 1, and the text names the document and page so a result can
  be told apart from its neighbours.
  """
  def indexed_page_fixture(document, attrs \\ %{}) do
    page_number = Map.get(attrs, :page_number, 1)

    page_fixture(
      document,
      Enum.into(attrs, %{
        page_number: page_number,
        image_path: "documents/#{document.id}/pages/page_#{page_number}.png",
        extraction_status: "completed",
        original_markdown: "Content in document #{document.title} page #{page_number}",
        translation_status: "completed",
        translated_markdown: "Translated content page #{page_number}",
        embedding_status: "completed",
        embedding: fake_embedding()
      })
    )
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

    page = page_fixture(document, Map.put(attrs, :original_markdown, text))

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
  Creates a completed page (extraction and translation done) through the real
  transitions, silently.

  `attrs` go to the page row, except `:extraction_model` and
  `:translation_model`, which are recorded as the models that completed the
  two stages.
  """
  def completed_page_fixture(document, attrs \\ %{}) do
    page_fixture(
      document,
      Enum.into(attrs, %{
        extraction_status: "completed",
        original_markdown: "# Original Content\n\nSome text here.",
        translation_status: "completed",
        translated_markdown: "# Translated Content\n\nSome translated text."
      })
    )
  end
end
