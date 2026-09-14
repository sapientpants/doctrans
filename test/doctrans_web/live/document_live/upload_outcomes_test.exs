defmodule DoctransWeb.DocumentLive.UploadOutcomesTest do
  use DoctransWeb.ConnCase, async: false

  alias Doctrans.Documents
  alias DoctransWeb.DocumentLive.UploadIntake

  import Doctrans.Fixtures

  @moduletag :capture_log

  setup do
    previous_uploads = Application.fetch_env!(:doctrans, :uploads)
    previous_extractor = Application.fetch_env!(:doctrans, :pdf_extractor_module)
    directory = Path.join(System.tmp_dir!(), "upload-outcomes-#{Uniq.UUID.uuid7()}")
    File.mkdir_p!(directory)

    Application.put_env(:doctrans, :uploads,
      upload_dir: directory,
      max_file_size: 100_000
    )

    Application.put_env(:doctrans, :pdf_extractor_module, Doctrans.UploadPathExtractorStub)

    on_exit(fn ->
      Application.put_env(:doctrans, :uploads, previous_uploads)
      Application.put_env(:doctrans, :pdf_extractor_module, previous_extractor)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  describe "reporting a mixed submission" do
    test "names the rejected file in the modal while storing the accepted one", %{
      conn: conn,
      directory: directory
    } do
      view =
        upload_files(conn, [
          %{name: "report.pdf", content: pdf_content()},
          %{name: "broken.pdf", content: "not a pdf at all"}
        ])

      [document] = Documents.list_documents()
      assert document.original_filename == "report.pdf"
      assert has_element?(view, "#documents-#{document.id}")

      # The modal carries the per-file outcome and stays open to show it.
      assert has_element?(view, "#upload-modal")
      assert has_element?(view, "#upload-failures")

      assert has_element?(
               view,
               ~s{#upload-failures [data-failed-upload="broken.pdf"]},
               "File content does not match its extension"
             )

      refute has_element?(view, ~s{[data-failed-upload="report.pdf"]})

      # The rejected file left nothing behind on disk.
      assert File.ls!(Path.join(directory, "documents")) == [document.id]
    end

    test "counts only the documents that actually started processing", %{
      conn: conn,
      directory: directory
    } do
      # "_.pdf" passes the magic-byte check and is stored, then fails document
      # creation because its title derives to an empty string.
      view =
        upload_files(conn, [
          %{name: "report.pdf", content: pdf_content()},
          %{name: "_.pdf", content: pdf_content()}
        ])

      [document] = Documents.list_documents()

      assert has_element?(view, "#flash-info", "Document uploaded!")
      refute has_element?(view, "#flash-info", "2 documents uploaded!")

      # The flash renders under the open modal's backdrop, so the same count is
      # reported inside the modal where it can actually be read.
      assert has_element?(view, "#upload-started", "Document uploaded!")
      refute has_element?(view, "#upload-started", "2 documents uploaded!")

      assert has_element?(
               view,
               ~s{#upload-failures [data-failed-upload="_.pdf"]},
               "Title cannot be empty"
             )

      assert has_element?(view, "#upload-modal")
      assert File.ls!(Path.join(directory, "documents")) == [document.id]
    end
  end

  describe "reporting a submission where nothing started" do
    test "lists every rejected file without a flash nobody could see", %{
      conn: conn,
      directory: directory
    } do
      view =
        upload_files(conn, [
          %{name: "first.pdf", content: "not a pdf at all"},
          %{name: "second.pdf", content: "also not a pdf"}
        ])

      # No flash for this case: the modal stays open to carry the list, and its
      # backdrop covers the toast until the toast dismisses itself unseen.
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
      refute has_element?(view, "#upload-started")
      assert has_element?(view, ~s{#upload-failures [data-failed-upload="first.pdf"]})
      assert has_element?(view, ~s{#upload-failures [data-failed-upload="second.pdf"]})
      assert has_element?(view, "#upload-modal")

      assert Documents.list_documents() == []
      assert File.ls!(directory) == []
    end

    test "reports a file that could not be stored", %{conn: conn, directory: directory} do
      # A storage root whose parent is a regular file: `mkdir_p` fails with
      # :enotdir, so the move into the document directory cannot happen.
      blocker = Path.join(directory, "not-a-directory")
      File.write!(blocker, "")

      Application.put_env(:doctrans, :uploads,
        upload_dir: Path.join(blocker, "uploads"),
        max_file_size: 100_000
      )

      view = upload_files(conn, [%{name: "report.pdf", content: pdf_content()}])

      refute has_element?(view, "#flash-error")

      assert has_element?(
               view,
               ~s{#upload-failures [data-failed-upload="report.pdf"]},
               "Could not store the uploaded file"
             )

      assert Documents.list_documents() == []
      # Nothing was written beside the blocked root either.
      assert File.ls!(directory) == ["not-a-directory"]
    end
  end

  describe "reporting entries the browser rejected" do
    # An entry the browser rejected never finishes uploading; before it is dropped
    # it makes `consume_uploaded_entries/3` raise for the whole submission. The
    # accepted file is added first because the upload config refuses to preflight
    # anything once one of its entries is in error.
    test "keeps the accepted file when an entry is over the size limit", %{
      conn: conn,
      directory: directory
    } do
      Application.put_env(:doctrans, :uploads,
        upload_dir: directory,
        max_file_size: 1_000_000
      )

      view = open_upload_modal(conn)
      add_file(view, "report.pdf", pdf_content())

      assert {:error, [[_ref, :too_large]]} =
               add_file(view, "huge.pdf", pdf_content(2_500_000))

      submit_upload(view)

      [document] = Documents.list_documents()
      assert document.original_filename == "report.pdf"
      assert has_element?(view, "#documents-#{document.id}")
      assert has_element?(view, "#upload-started", "Document uploaded!")

      assert has_element?(
               view,
               ~s{#upload-failures [data-failed-upload="huge.pdf"]},
               "File too large (3MB, max 1MB)"
             )

      assert File.ls!(Path.join(directory, "documents")) == [document.id]
    end

    test "keeps the accepted file when an entry has an unsupported extension", %{
      conn: conn,
      directory: directory
    } do
      view = open_upload_modal(conn)
      add_file(view, "report.pdf", pdf_content())

      assert {:error, [[_ref, :not_accepted]]} = add_file(view, "notes.txt", "plain text file")

      submit_upload(view)

      [document] = Documents.list_documents()
      assert document.original_filename == "report.pdf"
      assert has_element?(view, "#upload-started", "Document uploaded!")

      assert has_element?(
               view,
               ~s{#upload-failures [data-failed-upload="notes.txt"]},
               "Unsupported file format: .txt"
             )

      assert File.ls!(Path.join(directory, "documents")) == [document.id]
    end

    test "survives a rejected entry that arrives before the file it blocks", %{conn: conn} do
      # Once an entry is in error the whole upload config preflights as an error, so
      # a file added after one never uploads and never becomes `done?`. Submitting in
      # that state used to raise out of the consume and take the socket with it.
      view = open_upload_modal(conn)

      assert {:error, [[_ref, :not_accepted]]} = add_file(view, "notes.txt", "plain text file")

      add_file(view, "report.pdf", pdf_content())
      submit_upload(view)

      assert has_element?(
               view,
               ~s{#upload-failures [data-failed-upload="notes.txt"]},
               "Unsupported file format: .txt"
             )

      # The file that never finished uploading is still listed, not thrown away with
      # the entry that blocked it, and it is named as still uploading rather than
      # silently dropped from the report.
      assert has_element?(view, "#upload-modal", "report.pdf")
      refute has_element?(view, ~s{[data-failed-upload="report.pdf"]})
      assert has_element?(view, ~s{#upload-pending [data-pending-upload="report.pdf"]})
      assert Documents.list_documents() == []
    end

    test "explains a rejected entry where it sits, before any submission", %{conn: conn} do
      view = open_upload_modal(conn)

      assert {:error, [[ref, :not_accepted]]} = add_file(view, "notes.txt", "plain text file")

      # The reason is on the entry itself. `upload_errors/1` returns only the
      # config's own errors, so without this the browser's rejection is explained
      # nowhere until the user submits.
      assert has_element?(
               view,
               ~s{[data-entry-error="#{ref}"]},
               "Unsupported file format: .txt"
             )
    end

    test "names no format for a file that has no extension", %{conn: conn} do
      view = open_upload_modal(conn)

      assert {:error, [[ref, :not_accepted]]} = add_file(view, "README", "plain text file")

      # `Path.extname("README")` is "", which would render as a dangling colon.
      assert has_element?(
               view,
               ~s{[data-entry-error="#{ref}"]},
               "Only PDF, Word, OpenDocument, and RTF documents are accepted"
             )
    end

    test "blocks the submission while an entry is in error", %{conn: conn} do
      view = open_upload_modal(conn)
      add_file(view, "report.pdf", pdf_content())

      assert has_element?(view, "#start-translation-btn:not([disabled])")

      assert {:error, [[_ref, :not_accepted]]} = add_file(view, "notes.txt", "plain text file")

      # Submitting here would fail the whole config's preflight, and LiveView
      # cancels every entry on that failure -- taking report.pdf with it and
      # telling the server about neither.
      assert has_element?(view, "#start-translation-btn[disabled]")
    end
  end

  describe "reporting a submission where everything started" do
    test "closes the modal and reports nothing left over", %{conn: conn} do
      view = upload_files(conn, [%{name: "report.pdf", content: pdf_content()}])

      [document] = Documents.list_documents()

      refute has_element?(view, "#upload-modal")
      refute has_element?(view, "#upload-outcomes")
      refute has_element?(view, "#upload-failures")
      assert has_element?(view, "#flash-info", "Document uploaded!")
      assert has_element?(view, "#documents-#{document.id}")
    end
  end

  describe "clearing reported failures" do
    test "reopening the upload modal drops the previous failures", %{conn: conn} do
      view = upload_files(conn, [%{name: "broken.pdf", content: "not a pdf at all"}])

      assert has_element?(view, "#upload-failures")

      view |> element("#upload-document-btn") |> render_click()

      assert has_element?(view, "#upload-modal")
      refute has_element?(view, "#upload-failures")
    end

    test "picking new files drops the previous failures", %{conn: conn} do
      view = upload_files(conn, [%{name: "broken.pdf", content: "not a pdf at all"}])

      assert has_element?(view, "#upload-failures")

      add_file(view, "report.pdf", pdf_content())
      # `render_upload/2` does not fire the form's `phx-change`, which is what a
      # browser does when files are picked, so the change is sent explicitly.
      # `_target` is the file input's name, as the browser reports it.
      render_change(view, "validate_upload", %{
        "_target" => ["document"],
        "target_language" => "en"
      })

      refute has_element?(view, "#upload-failures")
      assert has_element?(view, "#upload-modal")
    end

    test "changing the target language keeps the failures on screen", %{conn: conn} do
      view = upload_files(conn, [%{name: "broken.pdf", content: "not a pdf at all"}])

      assert has_element?(view, "#upload-failures")

      render_change(view, "validate_upload", %{
        "_target" => ["target_language"],
        "target_language" => "fr"
      })

      # Reading the list is not retrying the upload, so the explanation stays.
      assert has_element?(view, ~s{#upload-failures [data-failed-upload="broken.pdf"]})
    end

    test "a submission with no entries clears the previous outcomes", %{conn: conn} do
      view =
        upload_files(conn, [
          %{name: "report.pdf", content: pdf_content()},
          %{name: "broken.pdf", content: "not a pdf at all"}
        ])

      assert has_element?(view, "#upload-started")
      assert has_element?(view, "#upload-failures")

      render_submit(view, "upload_document", %{"target_language" => "en"})

      assert has_element?(view, "#flash-error", "No files were uploaded")
      refute has_element?(view, "#upload-started")
      refute has_element?(view, "#upload-failures")
      assert has_element?(view, "#upload-modal")
    end
  end

  describe "create_and_process/2" do
    test "reports a failure and keeps nothing when the job cannot be queued" do
      # The extraction job refuses any extension outside the accepted list, so a
      # stored ".txt" path exercises the enqueue failure without stubbing Oban.
      {document_id, path} = stored_upload("original.txt")

      assert {:error, "notes.txt", {:unsupported_format, [format: ".txt"]}} =
               UploadIntake.create_and_process({:ok, document_id, "notes.txt", path}, "en")

      assert Documents.list_documents() == []
      refute File.exists?(Documents.document_upload_dir(document_id))
    end

    test "reports a failure and removes the upload when the document cannot be created" do
      {document_id, path} = stored_upload("original.pdf")

      assert {:error, "_.pdf", :empty_title} =
               UploadIntake.create_and_process({:ok, document_id, "_.pdf", path}, "en")

      assert Documents.list_documents() == []
      refute File.exists?(Documents.document_upload_dir(document_id))
    end

    test "reports a start failure and cleans up when the start path raises" do
      # A second insert of the same id raises `Ecto.ConstraintError` (the schema
      # declares no unique constraint to turn it into a changeset error), standing
      # in for the raises an unreachable database produces mid-start.
      existing = document_fixture()
      directory = Documents.document_upload_dir(existing.id)
      File.mkdir_p!(directory)
      path = Path.join(directory, "original.pdf")
      File.write!(path, pdf_content())

      assert {:error, "dupe.pdf", :upload_start_failed} =
               UploadIntake.create_and_process({:ok, existing.id, "dupe.pdf", path}, "en")

      # The insert never completed, so this call has no row to claim: cleanup takes
      # the directory it was handed and nothing else. Deleting whatever happens to
      # sit at that id is how a caller's own document would be destroyed by a
      # failure that had nothing to do with it.
      assert [kept] = Documents.list_documents()
      assert kept.id == existing.id
      refute File.exists?(directory)
    end

    test "deletes only the document it created when the enqueue raises" do
      # Past the insert the row is this call's own, so cleanup may delete it.
      bystander = document_fixture()
      {document_id, path} = stored_upload("original.pdf")

      assert {:error, "notes.pdf", :upload_start_failed} =
               UploadIntake.create_and_process(
                 {:ok, document_id, "notes.pdf", nil},
                 "en"
               )

      assert [kept] = Documents.list_documents()
      assert kept.id == bystander.id
      refute File.exists?(Documents.document_upload_dir(document_id))
      refute File.exists?(path)
    end
  end

  defp stored_upload(basename) do
    document_id = Uniq.UUID.uuid7()
    directory = Documents.document_upload_dir(document_id)
    File.mkdir_p!(directory)
    path = Path.join(directory, basename)
    File.write!(path, pdf_content())

    on_exit(fn -> File.rm_rf!(directory) end)

    {document_id, path}
  end

  defp upload_files(conn, files) do
    view = open_upload_modal(conn)
    Enum.each(files, fn file -> add_file(view, file.name, file.content) end)
    submit_upload(view)

    view
  end

  defp open_upload_modal(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#upload-document-btn") |> render_click()

    view
  end

  # One `file_input` per file, the way the modal's "add more files" label works:
  # LiveViewTest's upload client process is linked to the channel of every entry
  # it holds, so consuming the first entry of a multi-entry input takes the
  # sibling entries' channels down before the LiveView can consume them.
  defp add_file(view, name, content) do
    upload =
      file_input(view, "#upload-form", :document, [
        %{name: name, content: content, type: "application/octet-stream"}
      ])

    render_upload(upload, name)
  end

  defp submit_upload(view) do
    view |> form("#upload-form", %{target_language: "en"}) |> render_submit()
  end

  defp pdf_content, do: pdf_content(32)

  defp pdf_content(size), do: "%PDF-1.7\n" <> String.duplicate("x", size - 9)
end
