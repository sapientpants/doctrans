defmodule Doctrans.Integration.ReprocessingBoundaryTest do
  @moduledoc """
  The `processing_generation` guard, from the two sides a stale job can arrive
  on.

  Reprocessing stamps a page with a new generation; every job queued for the old
  one is then a job whose work has already been replaced. `LlmProcessor` refuses
  to run such a job, and a run superseded mid-flight can neither write its stage
  states onto the page that replaced it nor settle the document on its account.
  The second half is the one with teeth: a stale run would otherwise leave its
  half-written stages on a page the new generation owns.

  Both cases install a model stub that raises on any call, so a run that was
  *not* refused announces itself instead of quietly succeeding. The stub is per
  test and `perform_job/3` runs in the test process, so the file runs
  concurrently with the rest of the suite.
  """
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{OpenAICrashStub, OpenAIMock, SupersedingCrashStub}

  @max_attempts 3

  test "a job queued for a superseded generation makes no model call and rewrites nothing" do
    Mox.stub_with(OpenAIMock, OpenAICrashStub)

    document = document_fixture(%{status: "processing", total_pages: 1})

    # Translation outstanding, so a run that was *not* refused would reach the
    # crashing stub rather than skipping both stages and looking the same.
    page =
      document
      |> page_fixture(%{
        extraction_status: "completed",
        original_markdown: "Text the current generation extracted",
        translation_status: "pending"
      })
      |> with_generation()

    superseded = Uniq.UUID.uuid7()
    refute superseded == page.processing_generation

    assert :ok =
             perform_job(
               LlmProcessingJob,
               %{"page_id" => page.id, "generation" => superseded},
               attempt: 1
             )

    current = Repo.get!(Page, page.id)
    assert current.processing_generation == page.processing_generation
    assert current.extraction_status == "completed"
    assert current.translation_status == "pending"
    assert current.original_markdown == page.original_markdown
    assert current.translated_markdown == nil
    assert current.content_revision == page.content_revision
    assert Repo.get!(Document, document.id).status == "processing"
  end

  test "a run superseded mid-flight writes nothing onto the page its replacement owns" do
    document = document_fixture(%{status: "processing", total_pages: 1})
    page = document |> page_fixture() |> with_generation()
    SupersedingCrashStub.install(page)

    # The last attempt is the one that settles the document on the page's
    # account, so it is the attempt on which the guard has the most to refuse.
    assert_raise RuntimeError, ~r/superseded/, fn ->
      perform_job(
        LlmProcessingJob,
        %{"page_id" => page.id, "generation" => page.processing_generation},
        attempt: @max_attempts
      )
    end

    assert Repo.get!(Document, document.id).status == "processing"
    assert Repo.get!(Document, document.id).error_message == nil

    # The page belongs to the generation that replaced the failed run, and holds
    # that generation's state rather than the crashed run's.
    current = Repo.get!(Page, page.id)
    refute current.processing_generation == page.processing_generation
    assert current.extraction_status == "pending"
    assert current.translation_status == "pending"
  end

  # The control for the test above: without it, the page assertions there would
  # also hold if a run never wrote a stage at all. A crash is not a page failure
  # -- the stage it interrupted stays `processing` -- so the document is not
  # failed on its account either; that is left to the recovery pass.
  test "the same crash on the current generation does reach the page" do
    Mox.stub_with(OpenAIMock, OpenAICrashStub)

    document = document_fixture(%{status: "processing", total_pages: 1})
    page = document |> page_fixture() |> with_generation()

    assert_raise RuntimeError, "extraction crashed", fn ->
      perform_job(
        LlmProcessingJob,
        %{"page_id" => page.id, "generation" => page.processing_generation},
        attempt: @max_attempts
      )
    end

    current = Repo.get!(Page, page.id)
    assert current.processing_generation == page.processing_generation
    assert current.extraction_status == "processing"
    assert Documents.get_document!(document.id).status == "processing"
  end

  defp with_generation(page) do
    page
    |> Ecto.Changeset.change(processing_generation: Uniq.UUID.uuid7())
    |> Repo.update!()
  end
end
