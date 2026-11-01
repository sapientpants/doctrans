defmodule Doctrans.Documents.LayoutTest do
  # Repoints the shared storage root, so it must not run alongside async tests.
  use Doctrans.EnvCase, async: false

  alias Doctrans.Documents.Layout
  alias Doctrans.TestEnv

  @root "/srv/doctrans-data"
  @document_id "0192f5c4-1a2b-7c3d-8e4f-5a6b7c8d9e0f"
  @run_id "0192f5c4-2b3c-7d4e-9f5a-6b7c8d9e0f1a"

  setup do
    TestEnv.put_env(:uploads, upload_dir: @root, max_file_size: 1)
    :ok
  end

  test "every path sits under the configured root" do
    assert Layout.root() == @root
    assert Layout.documents_dir() == "#{@root}/documents"
    assert Layout.document_dir(@document_id) == "#{@root}/documents/#{@document_id}"
  end

  test "the retained upload is named original plus the extension it arrived with" do
    assert Layout.original_path(@document_id, ".pdf") ==
             "#{@root}/documents/#{@document_id}/original.pdf"

    assert Layout.original_path(@document_id, ".docx") ==
             "#{@root}/documents/#{@document_id}/original.docx"
  end

  test "a run keeps its page images in its own directory" do
    assert Layout.runs_dir(@document_id) == "#{@root}/documents/#{@document_id}/runs"

    assert Layout.run_dir(@document_id, @run_id) ==
             "#{@root}/documents/#{@document_id}/runs/#{@run_id}"

    assert Layout.pages_dir(@document_id, @run_id) ==
             "#{@root}/documents/#{@document_id}/runs/#{@run_id}/pages"
  end

  test "a document from before runs existed keeps its pages beside the original" do
    assert Layout.legacy_pages_dir(@document_id) == "#{@root}/documents/#{@document_id}/pages"
  end

  test "stored page paths round-trip through the root" do
    relative = "documents/#{@document_id}/runs/#{@run_id}/pages/page-01.png"

    assert Layout.absolute(relative) == "#{@root}/#{relative}"
    assert Layout.relative(Layout.absolute(relative)) == relative
  end

  test "paths follow the root when it moves at runtime" do
    TestEnv.put_env(:uploads, upload_dir: "/mnt/moved", max_file_size: 1)

    assert Layout.document_dir(@document_id) == "/mnt/moved/documents/#{@document_id}"
  end
end
