# The suite deletes directories beneath the storage root, so refuse to run
# against anything but the root `config/test.exs` configures. This is a tripwire
# for any future path that repoints the root -- a stray environment variable, a
# leaked `Application.put_env` -- which would otherwise erase real documents
# while the suite reported success.
expected_upload_root = Path.expand("../tmp/uploads_test", __DIR__)
actual_upload_root = Doctrans.Config.Uploads.upload_dir()

if actual_upload_root != expected_upload_root do
  raise """
  refusing to run the test suite against storage root #{actual_upload_root}.

  Expected #{expected_upload_root}. The suite removes directories under its
  storage root, so it must never point at real data.
  """
end

# Tests create per-run directories under the test root and few clean up after
# themselves; drop the whole root once the VM is done with it.
System.at_exit(fn _status -> File.rm_rf(expected_upload_root) end)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Doctrans.Repo, :manual)

# Define mocks for external services
Mox.defmock(Doctrans.Search.EmbeddingMock, for: Doctrans.Search.EmbeddingBehaviour)
Mox.defmock(Doctrans.Processing.OpenAIMock, for: Doctrans.Processing.OpenAIBehaviour)
Mox.defmock(Doctrans.Processing.PdfExtractorMock, for: Doctrans.Processing.PdfExtractorBehaviour)

# Set global mode so stubs work across process boundaries (LiveView tests)
Mox.set_mox_global()

# Set up default stubs for mocks
Mox.stub_with(Doctrans.Search.EmbeddingMock, Doctrans.Search.EmbeddingStub)
Mox.stub_with(Doctrans.Processing.OpenAIMock, Doctrans.Processing.OpenAIStub)
Mox.stub_with(Doctrans.Processing.PdfExtractorMock, Doctrans.Processing.PdfExtractorStub)
