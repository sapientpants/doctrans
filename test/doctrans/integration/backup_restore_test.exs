defmodule Doctrans.Integration.BackupRestoreTest do
  @moduledoc """
  A backed-up document restored into a *different* storage root, driven through
  all four things a restored document is supposed to still be good for: viewing,
  search, chat, and reprocessing from its retained source.

  The units below this one each hold one end of that claim. `Config.Uploads`
  resolves the root on every call, `PdfProcessor` persists page paths relative
  to it, `Run.source_path/1` rebuilds the retained original's path from it, and
  `Doctrans.StorageRootTest` proves the endpoint serves images from whichever
  root is configured at the time. None of them establishes that a document
  *written* under one absolute root is whole under another -- that no stage on
  the viewing, retrieval, chat or reprocessing paths kept a path from the root
  it was created under. That is the whole of what restoring onto a new machine,
  volume, or container does, so it is what happens here: the pipeline runs for
  real under root A, the `documents/` tree is copied to root B, root A is then
  deleted outright so nothing can be answered from it by accident, and every
  verb is driven against root B.

  The negative at the end is what gives the positive its meaning. A database
  restored without the files that belong to it still views -- the rows and the
  page images are there -- but can no longer be reprocessed, because the
  retained original the restart reads is missing. That is the failure the
  backup procedure's ordering rule exists to prevent.

  Async: `:uploads` and `:openai_module` are both application-global, and this
  test repoints the storage root out from under the whole VM.
  """
  use DoctransWeb.ConnCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Chat
  alias Doctrans.Chat.Conversations
  alias Doctrans.Documents
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.{DocumentReprocessing, PageContentStub, Run}
  alias Doctrans.Search
  alias Doctrans.TestEnv

  @title "Jahresabschluss 2025"
  @question "Welcher Abschnitt nennt das Wertpapierportfolio?"
  @answer "Seite 2 nennt den Bestand zum Stichtag."
  @follow_up "Und die Pensionsrueckstellungen?"

  setup :stub_models
  setup :process_under_original_root

  describe "a restore that carries the whole storage tree" do
    setup :restore_everything

    test "the document renders and its page images are served from the new root", %{
      conn: conn,
      document: document,
      pages: pages,
      original_root: original_root,
      restored_root: restored_root
    } do
      # Nothing below can be satisfied by the location the files were written
      # under: it is gone.
      refute File.exists?(original_root)

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      first = hd(pages)
      assert has_element?(view, ~s(img[src="/uploads/#{first.image_path}"]))

      for page <- pages do
        restored_image = Path.join(restored_root, page.image_path)
        assert File.regular?(restored_image)

        served = get(build_conn(), "/uploads/" <> page.image_path)
        assert response(served, 200) == File.read!(restored_image)
        assert get_resp_header(served, "cache-control") == ["private, no-store"]
      end

      # The retained original travelled with the backup and is still not an
      # asset: a restore must not widen what the endpoint hands out.
      assert File.regular?(Run.source_path(document))
      assert get(build_conn(), "/uploads/documents/#{document.id}/original.pdf").status == 404
    end

    test "a search a single page can answer returns that page of the restored document", %{
      document: document,
      pages: pages,
      restored_root: restored_root
    } do
      target = Enum.at(pages, 1)

      assert {:ok, %{results: [top | rest], total_count: 3, retrieval: :hybrid}} =
               Search.search_with_count(PageContentStub.source_term(2))

      assert top.page_id == target.id
      assert top.document_id == document.id
      assert top.page_number == 2
      assert top.document_title == @title
      assert top.image_path == target.image_path
      assert top.snippet =~ PageContentStub.translated_term(2)

      # The rest of the document ranks behind it rather than being absent, so
      # the index survived the move whole and not just for the matched page.
      assert Enum.sort([top.page_number | Enum.map(rest, & &1.page_number)]) == [1, 2, 3]

      # The path a result hands the browser resolves under the root the restore
      # put the files in, not the one they were written under.
      assert File.regular?(Path.join(restored_root, top.image_path))
    end

    test "the saved conversation comes back with its context and takes a new turn", %{
      conn: conn,
      document: document,
      answer: answer,
      context: context
    } do
      saved = Conversations.load(document.id)

      assert saved.history == [
               %{role: "user", content: @question},
               %{role: "assistant", content: @answer}
             ]

      assert saved.context == context
      refute saved.interrupted?
      assert Documents.embeddings_ready?(document)

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("header button[phx-click='toggle_chat']") |> render_click()
      assert has_element?(view, "#chat_messages-#{answer.id}")

      # And a fresh question runs end to end against the restored index rather
      # than only replaying what was already stored. The document-scoped
      # retrieval the answer is built from is checked first, so a reply that
      # came back with no context behind it would not read as a success.
      assert {:ok, [_ | _] = hits} =
               Search.search_in_document(document.id, PageContentStub.source_term(3))

      assert Enum.any?(hits, &(&1.page_number == 3))

      pending = Conversations.start_question(document.id, @follow_up)
      assert {:ok, reply} = Chat.send_message(document, @follow_up, saved.history)
      assert is_binary(reply) and reply != ""
      assert {:ok, _} = Conversations.finish(pending, "assistant", reply, context)

      assert Conversations.load(document.id).history == [
               %{role: "user", content: @question},
               %{role: "assistant", content: @answer},
               %{role: "user", content: @follow_up},
               %{role: "assistant", content: reply}
             ]
    end

    test "reprocessing reads the retained source and writes its pages under the new root", %{
      document: document,
      pages: pages,
      restored_root: restored_root
    } do
      assert Run.source_available?(document)
      assert String.starts_with?(Run.source_path(document), restored_root <> "/")

      # Oban is inline in :test, so this one call drives page rendering and both
      # model stages for every page of the fresh run.
      assert {:ok, restarted} = DocumentReprocessing.reprocess_document(document.id)
      refute restarted.processing_run_id == document.processing_run_id

      reprocessed = Documents.get_document_with_pages!(document.id)
      assert reprocessed.status == "completed"
      fresh = Enum.sort_by(reprocessed.pages, & &1.page_number)

      assert Enum.map(fresh, & &1.page_number) == [1, 2, 3]
      assert MapSet.disjoint?(MapSet.new(fresh, & &1.id), MapSet.new(pages, & &1.id))

      for page <- fresh do
        assert page.extraction_status == "completed"
        assert page.translation_status == "completed"
        assert page.original_markdown == PageContentStub.source_markdown(page.page_number)
        assert page.translated_markdown == PageContentStub.translated_markdown(page.page_number)

        # Written by this run, under the root the restore chose, and reachable
        # over HTTP from there without anything having rewritten a stored path.
        assert page.image_path =~ restarted.processing_run_id
        restored_image = Path.join(restored_root, page.image_path)
        assert File.regular?(restored_image)

        assert response(get(build_conn(), "/uploads/" <> page.image_path), 200) ==
                 File.read!(restored_image)
      end
    end
  end

  describe "a restore whose file copy missed the retained source" do
    setup :restore_without_retained_source

    test "leaves the document viewable but refuses to reprocess it", %{
      conn: conn,
      document: document,
      pages: pages,
      restored_root: restored_root
    } do
      # Everything the database alone can answer still works.
      page = hd(pages)
      assert File.regular?(Path.join(restored_root, page.image_path))
      assert {:ok, _view, _html} = live(conn, ~p"/documents/#{document.id}")
      assert get(build_conn(), "/uploads/" <> page.image_path).status == 200
      assert Conversations.load(document.id).history != []

      # The source the restart would read is what the copy left behind.
      refute File.exists?(Run.source_path(document))
      refute Run.source_available?(document)

      assert {:error, :original_upload_missing} =
               DocumentReprocessing.reprocess_document(document.id)

      # And the refusal rolled back whole, rather than discarding the pages and
      # then discovering the source was gone.
      unchanged = Documents.get_document_with_pages!(document.id)
      assert unchanged.status == "completed"
      assert unchanged.processing_run_id == document.processing_run_id
      assert MapSet.new(unchanged.pages, & &1.id) == MapSet.new(pages, & &1.id)
    end
  end

  defp stub_models(_context) do
    TestEnv.put_env(:openai_module, PageContentStub)
    :ok
  end

  # Builds the document the way an operator's machine did: a real run of the
  # pipeline, with only the models stubbed, under a storage root of its own.
  defp process_under_original_root(_context) do
    roots = prepare_roots()
    repoint(roots.previous_uploads, roots.original_root)
    processed = process_document(roots.original_root)

    roots
    |> Map.merge(processed)
    |> Map.merge(seed_conversation(processed.document, Enum.at(processed.pages, 1)))
  end

  defp prepare_roots do
    previous = Application.fetch_env!(:doctrans, :uploads)
    original_root = temp_root("original")
    restored_root = temp_root("restored")

    on_exit(fn ->
      # Restore the shared root before removing either temporary one: the suite
      # refuses to run against any root but the configured one.
      Application.put_env(:doctrans, :uploads, previous)
      File.rm_rf!(original_root)
      File.rm_rf!(restored_root)
    end)

    %{previous_uploads: previous, original_root: original_root, restored_root: restored_root}
  end

  defp process_document(original_root) do
    document =
      document_fixture(%{
        title: @title,
        original_filename: "jahresabschluss.pdf",
        target_language: "en"
      })

    source = document_source_fixture(document)
    assert String.starts_with?(source, original_root <> "/")

    # Oban runs inline in :test, so this one call drives page rendering, both
    # model stages for every page, and indexing.
    assert {:ok, _job} = DocumentExtractionJob.enqueue_document(document.id, source)

    document = Documents.get_document_with_pages!(document.id)
    pages = Enum.sort_by(document.pages, & &1.page_number)

    assert document.status == "completed"
    assert Enum.map(pages, & &1.page_number) == [1, 2, 3]
    assert Enum.all?(pages, &File.regular?(Path.join(original_root, &1.image_path)))

    %{
      document: document,
      pages: pages,
      source_relative: Path.relative_to(source, original_root)
    }
  end

  defp seed_conversation(document, page) do
    context = [context_chunk(page)]
    question = Conversations.start_question(document.id, @question)
    assert {:ok, answer} = Conversations.finish(question, "assistant", @answer, context)
    %{context: context, answer: answer}
  end

  defp restore_everything(context) do
    copy_documents_tree(context)
    move_in(context)
  end

  # The same restore with one file missing from the copy -- the case a backup
  # taken while the upload was still landing, or dumped before the files were
  # captured, leaves behind.
  defp restore_without_retained_source(context) do
    copy_documents_tree(context)
    File.rm!(Path.join(context.restored_root, context.source_relative))
    move_in(context)
  end

  defp copy_documents_tree(%{original_root: original, restored_root: restored}) do
    File.mkdir_p!(restored)
    File.cp_r!(Path.join(original, "documents"), Path.join(restored, "documents"))
  end

  # Deleting the root the files came from is the point: without it every
  # assertion below could be satisfied by a path still pointing at it.
  defp move_in(context) do
    File.rm_rf!(context.original_root)
    repoint(context.previous_uploads, context.restored_root)
    :ok
  end

  defp repoint(previous, root) do
    Application.put_env(:doctrans, :uploads, Keyword.put(previous, :upload_dir, root))
  end

  defp temp_root(name), do: Path.join(System.tmp_dir!(), "doctrans-#{name}-#{Uniq.UUID.uuid7()}")

  defp context_chunk(page) do
    %{
      page_id: page.id,
      page_number: page.page_number,
      chunk_index: 0,
      content_revision: page.content_revision,
      similarity: 0.9,
      original_markdown: page.original_markdown,
      translated_markdown: nil
    }
  end
end
