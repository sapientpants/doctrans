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
