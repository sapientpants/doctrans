defmodule Doctrans.Mocks do
  @moduledoc """
  Per-test setup for the Mox mocks that stand in for external services.

  `config/test.exs` points every configurable collaborator at a mock, so a test
  that installs nothing would fail its first call with
  `Mox.UnexpectedCallError`. `setup/1` installs the suite's defaults instead --
  the same fake responses the old stub modules gave -- and a test narrows them
  with `Mox.stub/3`, `Mox.expect/4` or `Mox.stub_with/2` where it needs to.

  Mode follows the test's `async` tag through `Mox.set_mox_from_context/1`. An
  async test gets private mode, where only the processes it spawned see its
  stubs -- Mox follows `$callers`, which LiveViews under test, `start_async`
  tasks, supervised tasks and inline Oban jobs all carry, and otherwise the
  process parent chain -- and a concurrent test sees its own. An `async: false`
  test gets global mode, so a process the application started on its own -- a
  GenServer whose `$callers` lead nowhere -- still reaches that test's stubs.
  """

  import Mox

  alias Doctrans.Processing.{
    DocumentConverter,
    DocumentConverterMock,
    OpenAIMock,
    OpenAIStub,
    PdfExtractorMock,
    PdfExtractorStub
  }

  alias Doctrans.Search.{EmbeddingMock, EmbeddingStub}

  @defaults [
    {EmbeddingMock, EmbeddingStub},
    {OpenAIMock, OpenAIStub},
    {PdfExtractorMock, PdfExtractorStub},
    {DocumentConverterMock, DocumentConverter}
  ]

  @doc """
  Selects the Mox mode for the running test and installs the default stubs.

  Called once per test from `Doctrans.DataCase`, `DoctransWeb.ConnCase` and
  `Doctrans.EnvCase`. Expectations set with `Mox.expect/4` are verified when the
  test exits.
  """
  def setup(tags) do
    set_mox_from_context(tags)
    verify_on_exit!(tags)
    stub_defaults()
    :ok
  end

  @doc """
  Installs the default stub on every mock, replacing any narrower stub.
  """
  def stub_defaults do
    for {mock, default} <- @defaults, do: stub_with(mock, default)
    :ok
  end
end
