defmodule Doctrans.Processing.ResumablePdfExtractorStub do
  @moduledoc """
  A page extractor the calling process can pause or fail on a chosen page.

  `install/0` stubs `extract_page/4` on `Doctrans.Processing.PdfExtractorMock`
  for the running test; the other callbacks keep the default stub. Each
  extracted page is reported to the extracting process as
  `{:extracted_pdf_page, page_number}`. With `:pause_pdf_page` set to
  `{page_number, owner}` in that process's dictionary, the stub tells `owner`
  `{:pdf_page_paused, page_number}` and waits for `:resume_pdf`; with
  `:fail_pdf_page` set to a page number, that page fails with `:invalid_pdf`.

  `await_pause/2` is the owner's side of the pause: it waits for the message
  and, when it does not come, fails with the extracting task's current stack
  trace instead of a bare timeout.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Mox

  alias Doctrans.Processing.{PdfExtractorMock, PdfExtractorStub}

  # One deadline on both sides of the pause: the owner waits this long for the
  # extracting task to reach the page, and the task waits this long to be
  # resumed. It matches the suite's other cross-process waits.
  @timeout 5_000

  @doc "Routes `extract_page/4` through this stub for the running test."
  def install do
    stub(PdfExtractorMock, :extract_page, &extract_page/4)
    :ok
  end

  @doc """
  Waits for `task` to pause on `page_number`.

  A stall inside the task -- a database call that does not return, for one --
  shows up here as a timeout, so the failure names the call the task is in
  rather than only the message that did not arrive.
  """
  @spec await_pause(Task.t(), pos_integer()) :: :ok
  def await_pause(%Task{pid: pid}, page_number) do
    receive do
      {:pdf_page_paused, ^page_number} -> :ok
    after
      @timeout ->
        flunk("""
        PDF extraction did not pause on page #{page_number} within #{@timeout}ms.
        The extracting task #{inspect(pid)} is at:

        #{current_location(pid)}
        """)
    end
  end

  def extract_page(path, directory, page_number, opts) do
    send(self(), {:extracted_pdf_page, page_number})

    case Process.get(:pause_pdf_page) do
      {^page_number, owner} ->
        send(owner, {:pdf_page_paused, page_number})

        receive do
          :resume_pdf -> :ok
        after
          @timeout -> raise "Timed out waiting to resume PDF extraction"
        end

      _ ->
        :ok
    end

    if Process.get(:fail_pdf_page) == page_number do
      {:error, :invalid_pdf}
    else
      PdfExtractorStub.extract_page(path, directory, page_number, opts)
    end
  end

  defp current_location(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stacktrace} -> Exception.format_stacktrace(stacktrace)
      nil -> "(already exited)"
    end
  end
end
