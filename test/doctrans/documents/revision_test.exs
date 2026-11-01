defmodule Doctrans.Documents.RevisionTest do
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.{Page, Revision}
  alias Doctrans.Repo

  defp replace_run(document) do
    document
    |> Ecto.Changeset.change(processing_run_id: Uniq.UUID.uuid7())
    |> Repo.update!()
  end

  describe "lock/1" do
    test "returns the document row, or nil once it is gone" do
      document = document_fixture()

      assert {:ok, %{id: id}} = Repo.transaction(fn -> Revision.lock(document.id) end)
      assert id == document.id

      Repo.delete!(document)
      assert {:ok, nil} = Repo.transaction(fn -> Revision.lock(document.id) end)
    end
  end

  describe "current?/2" do
    test "compares the stored run with the one the caller holds" do
      document = document_fixture()
      assert Revision.current?(document, document.processing_run_id)
      refute Revision.current?(document, Uniq.UUID.uuid7())
      refute Revision.current?(nil, document.processing_run_id)
    end
  end

  describe "with_current/2" do
    test "runs the function on the locked row while the run is unchanged" do
      document = document_fixture()

      assert {:ok, %{id: id}} = Revision.with_current(document, fn current -> {:ok, current} end)
      assert id == document.id
    end

    test "refuses a write planned against a replaced run" do
      document = document_fixture()
      _ = replace_run(document)

      assert {:error, :obsolete_run} =
               Revision.with_current(document, fn _ -> flunk("must not run") end)
    end

    test "refuses a write to a deleted document" do
      document = document_fixture()
      Repo.delete!(document)

      assert {:error, :obsolete_run} =
               Revision.with_current(document, fn _ -> flunk("must not run") end)
    end
  end

  describe "with_page/2" do
    test "runs the function on the locked page while its revision is unchanged" do
      page = page_fixture(document_fixture())

      assert {:ok, %{id: id}} = Revision.with_page(page, fn current -> {:ok, current} end)
      assert id == page.id
    end

    test "refuses a write once the content revision has advanced" do
      page = page_fixture(document_fixture())

      page
      |> Ecto.Changeset.change(content_revision: page.content_revision + 1)
      |> Repo.update!()

      assert {:error, :obsolete_run} =
               Revision.with_page(page, fn _ -> flunk("must not run") end)
    end

    test "refuses a write once the processing generation has changed" do
      page = page_fixture(document_fixture())

      page
      |> Ecto.Changeset.change(processing_generation: Uniq.UUID.uuid7())
      |> Repo.update!()

      assert {:error, :obsolete_run} =
               Revision.with_page(page, fn _ -> flunk("must not run") end)
    end

    test "refuses a write to a page whose document is gone" do
      document = document_fixture()
      page = page_fixture(document)
      Repo.delete!(document)
      refute Repo.get(Page, page.id)

      assert {:error, :obsolete_run} =
               Revision.with_page(page, fn _ -> flunk("must not run") end)
    end
  end
end
