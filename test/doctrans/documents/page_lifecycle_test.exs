defmodule Doctrans.Documents.PageLifecycleTest do
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Page, PageLifecycle, Topics}
  alias Doctrans.Repo

  setup do
    document = document_fixture(%{status: "processing", total_pages: 1})
    %{document: document, page: page_fixture(document)}
  end

  for stage <- [:extraction, :translation] do
    describe "#{stage}" do
      setup do
        %{stage: unquote(stage), fields: PageLifecycle.fields(unquote(stage))}
      end

      test "begin/2 marks the stage processing", %{page: page, stage: stage, fields: fields} do
        assert {:ok, %Page{} = begun} = PageLifecycle.begin(page, stage)
        assert Map.fetch!(begun, fields.status) == "processing"
        assert PageLifecycle.owed?(begun, stage)
      end

      test "complete/3 stores the product with the status, in one write", %{
        page: page,
        stage: stage,
        fields: fields
      } do
        assert {:ok, done} =
                 PageLifecycle.complete(page, stage, %{markdown: "# Text", model: "a-model"})

        assert Map.fetch!(done, fields.status) == "completed"
        assert Map.fetch!(done, fields.markdown) == "# Text"
        assert Map.fetch!(done, fields.model) == "a-model"
        assert PageLifecycle.done?(done, stage)
        refute PageLifecycle.owed?(done, stage)
      end

      test "complete/3 stores an empty product as nil", %{
        page: page,
        stage: stage,
        fields: fields
      } do
        assert {:ok, done} = PageLifecycle.complete(page, stage, %{markdown: ""})
        assert Map.fetch!(done, fields.status) == "completed"
        assert Map.fetch!(done, fields.markdown) == nil
      end

      test "complete/3 keeps the model when the product does not name one", %{
        page: page,
        stage: stage,
        fields: fields
      } do
        {:ok, modelled} = PageLifecycle.complete(page, stage, %{markdown: "x", model: "kept"})
        assert {:ok, done} = PageLifecycle.complete(modelled, stage, %{markdown: "y"})
        assert Map.fetch!(done, fields.model) == "kept"
      end

      test "complete/3 clears the model when the product names nil", %{
        page: page,
        stage: stage,
        fields: fields
      } do
        {:ok, modelled} = PageLifecycle.complete(page, stage, %{markdown: "x", model: "old"})
        assert {:ok, done} = PageLifecycle.complete(modelled, stage, %{markdown: "y", model: nil})
        assert Map.fetch!(done, fields.model) == nil
      end

      test "fail/2 marks the stage error and keeps what an earlier attempt produced", %{
        page: page,
        stage: stage,
        fields: fields
      } do
        {:ok, done} = PageLifecycle.complete(page, stage, %{markdown: "earlier"})
        assert {:ok, failed} = PageLifecycle.fail(done, stage)
        assert Map.fetch!(failed, fields.status) == "error"
        assert Map.fetch!(failed, fields.markdown) == "earlier"
        assert PageLifecycle.owed?(failed, stage)
      end
    end
  end

  describe "a transition touches only its own stage" do
    test "completing extraction leaves translation where it was", %{page: page} do
      {:ok, page} = PageLifecycle.begin(page, :translation)
      {:ok, page} = PageLifecycle.complete(page, :extraction, %{markdown: "src"})
      assert page.translation_status == "processing"
      assert page.translated_markdown == nil
    end
  end

  describe "release/1" do
    test "returns processing stages to pending and keeps everything else" do
      document = document_fixture(%{status: "processing", total_pages: 4})
      extracting = page_fixture(document, %{page_number: 1, extraction_status: "processing"})

      translating =
        page_fixture(document, %{
          page_number: 2,
          extraction_status: "completed",
          original_markdown: "Extracted text",
          translation_status: "processing"
        })

      failed = page_fixture(document, %{page_number: 3, extraction_status: "error"})
      done = completed_page_fixture(document, %{page_number: 4})

      assert {:ok, released} = PageLifecycle.release(document)
      assert Enum.sort(Enum.map(released, & &1.id)) == Enum.sort([extracting.id, translating.id])

      assert Documents.get_page!(extracting.id).extraction_status == "pending"

      settled = Documents.get_page!(translating.id)
      assert settled.translation_status == "pending"
      assert settled.extraction_status == "completed"
      assert settled.original_markdown == "Extracted text"

      assert Documents.get_page!(failed.id).extraction_status == "error"

      finished = Documents.get_page!(done.id)
      assert finished.translation_status == "completed"
      assert finished.translated_markdown == done.translated_markdown
    end

    test "announces each page it changed and none it did not" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      changed = page_fixture(document, %{page_number: 1, extraction_status: "processing"})
      _untouched = completed_page_fixture(document, %{page_number: 2})
      Topics.subscribe_document(document.id)

      assert {:ok, [_]} = PageLifecycle.release(document)
      assert_receive {:page_updated, %Page{id: id, extraction_status: "pending"}}
      assert id == changed.id
      refute_receive {:page_updated, _}
    end

    test "refuses once the document's run moved under the caller" do
      document = document_fixture(%{status: "processing", total_pages: 1})
      page_fixture(document, %{extraction_status: "processing"})

      document
      |> Ecto.Changeset.change(processing_run_id: Uniq.UUID.uuid7())
      |> Repo.update!()

      assert {:error, :obsolete_run} = PageLifecycle.release(document)
    end
  end

  describe "resume/1" do
    test "returns a failed stage to pending", %{page: page} do
      {:ok, failed} = PageLifecycle.fail(page, :translation)
      assert {:ok, resumed} = PageLifecycle.resume(failed)
      assert resumed.translation_status == "pending"
    end

    test "returns an interrupted stage to pending", %{page: page} do
      {:ok, begun} = PageLifecycle.begin(page, :translation)
      assert {:ok, resumed} = PageLifecycle.resume(begun)
      assert resumed.translation_status == "pending"
    end

    test "keeps a completed stage and its product", %{page: page} do
      {:ok, done} = PageLifecycle.complete(page, :extraction, %{markdown: "kept"})
      assert {:ok, resumed} = PageLifecycle.resume(done)
      assert resumed.extraction_status == "completed"
      assert resumed.original_markdown == "kept"
    end

    test "reads the stages the page holds now, not the copy the caller read", %{page: page} do
      {:ok, stale} = PageLifecycle.begin(page, :extraction)
      {:ok, _} = PageLifecycle.complete(stale, :extraction, %{markdown: ""})

      # The caller still holds the page as "processing"; the stage completed
      # since, at the same revision (an empty product leaves it alone).
      assert {:ok, resumed} = PageLifecycle.resume(stale)
      assert resumed.extraction_status == "completed"
    end
  end

  describe "reset/2" do
    test "starts the page over under a new generation with the requested models" do
      document = document_fixture(%{status: "completed", total_pages: 1})

      page =
        completed_page_fixture(document, %{
          extraction_model: "old-vision",
          translation_model: "old-text"
        })

      page =
        page
        |> Page.embedding_changeset(%{
          embedding: Pgvector.new(List.duplicate(0.5, 1024)),
          embedding_status: "completed"
        })
        |> Repo.update!()

      assert page.embedding != nil

      choices = %{extraction_model: "new-vision", translation_model: "new-text"}
      assert {:ok, reset} = PageLifecycle.reset(page, choices)

      assert reset.processing_generation != page.processing_generation
      assert reset.content_revision > page.content_revision
      assert reset.extraction_status == "pending"
      assert reset.translation_status == "pending"
      assert reset.embedding_status == "pending"
      assert reset.original_markdown == nil
      assert reset.translated_markdown == nil
      assert reset.embedding == nil
      assert reset.extraction_model == nil
      assert reset.translation_model == nil
      assert reset.requested_extraction_model == "new-vision"
      assert reset.requested_translation_model == "new-text"
    end

    test "returns a failed stage to pending", %{page: page} do
      {:ok, failed} = PageLifecycle.fail(page, :extraction)
      assert {:ok, reset} = PageLifecycle.reset(failed)
      assert reset.extraction_status == "pending"
    end

    test "records no requested model when none is chosen", %{page: page} do
      assert {:ok, reset} = PageLifecycle.reset(page)
      assert reset.requested_extraction_model == nil
      assert reset.requested_translation_model == nil
    end

    test "announces the page like every transition", %{document: document, page: page} do
      Topics.subscribe_document(document.id)
      {:ok, _} = PageLifecycle.reset(page)
      assert_receive {:page_updated, %Page{id: id}}
      assert id == page.id
    end

    test "is fenced like every transition: the caller's copy is a generation behind", %{
      page: page
    } do
      {:ok, moved} = PageLifecycle.reset(page)
      assert {:error, :obsolete_run} = PageLifecycle.reset(page)
      assert {:ok, _} = PageLifecycle.reset(moved)
    end
  end

  describe "the fence, once the page's generation moved under the caller" do
    setup %{page: page} do
      page
      |> Ecto.Changeset.change(processing_generation: Uniq.UUID.uuid7())
      |> Repo.update!()

      :ok
    end

    test "refuses begin/2 and writes nothing", %{page: page} do
      assert {:error, :obsolete_run} = PageLifecycle.begin(page, :extraction)
      assert Documents.get_page!(page.id).extraction_status == "pending"
    end

    test "refuses complete/3 and writes nothing", %{page: page} do
      assert {:error, :obsolete_run} = PageLifecycle.complete(page, :extraction, %{markdown: "x"})
      assert Documents.get_page!(page.id).original_markdown == nil
    end

    test "refuses fail/2 and writes nothing", %{page: page} do
      assert {:error, :obsolete_run} = PageLifecycle.fail(page, :extraction)
      assert Documents.get_page!(page.id).extraction_status == "pending"
    end
  end

  describe "the fence" do
    test "refuses once the page's content revision moved under the caller", %{page: page} do
      {:ok, _} = PageLifecycle.complete(page, :extraction, %{markdown: "newer text"})

      assert {:error, :obsolete_run} =
               PageLifecycle.complete(page, :translation, %{markdown: "x"})
    end

    test "refuses once the page is gone", %{document: document, page: page} do
      _ = Documents.delete_pages(document.id)
      assert {:error, :obsolete_run} = PageLifecycle.fail(page, :translation)
    end
  end

  describe "announcement" do
    test "a transition announces the page once it is written", %{document: document, page: page} do
      Topics.subscribe_document(document.id)
      {:ok, _} = PageLifecycle.begin(page, :extraction)
      assert_receive {:page_updated, %Page{id: id, extraction_status: "processing"}}
      assert id == page.id
    end

    test "inside a caller's transaction the announcement waits for the commit", %{
      document: document,
      page: page
    } do
      Topics.subscribe_document(document.id)

      {:ok, _} =
        Repo.safe_transaction(fn ->
          {:ok, _} = PageLifecycle.complete(page, :extraction, %{markdown: "x"})
          refute_received {:page_updated, _}
          :ok
        end)

      assert_receive {:page_updated, %Page{extraction_status: "completed"}}
    end

    test "a rolled-back transaction announces nothing", %{document: document, page: page} do
      Topics.subscribe_document(document.id)

      {:error, :changed_my_mind} =
        Repo.safe_transaction(fn ->
          {:ok, _} = PageLifecycle.complete(page, :extraction, %{markdown: "x"})
          Repo.rollback(:changed_my_mind)
        end)

      refute_receive {:page_updated, _}
      assert Documents.get_page!(page.id).extraction_status == "pending"
    end

    test "a refused transition announces nothing", %{document: document, page: page} do
      Topics.subscribe_document(document.id)
      _ = Documents.delete_pages(document.id)
      assert {:error, :obsolete_run} = PageLifecycle.begin(page, :extraction)
      refute_receive {:page_updated, _}
    end
  end
end
