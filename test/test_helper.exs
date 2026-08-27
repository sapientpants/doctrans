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
Mox.stub_with(Doctrans.Processing.OpenAIMock, Doctrans.Processing.OpenAIMock)
Mox.stub_with(Doctrans.Processing.PdfExtractorMock, Doctrans.Processing.PdfExtractorStub)
