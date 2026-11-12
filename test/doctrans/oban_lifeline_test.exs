defmodule Doctrans.ObanLifelineTest do
  @moduledoc """
  Holds `Oban.Lifeline`'s rescue window above every job's legitimate runtime.

  The rescue is purely time-based: a job still `executing` past the window is
  handed back to the queue as if its node had died, can no longer ack, and
  burns an attempt -- or is discarded on its last -- while its work goes on,
  with a second run possibly starting alongside (#272). Every job states its
  own ceiling as `timeout/1`, derived from the configured deadlines, so the
  window is correct exactly when it sits above all of them.

  Reads `config/config.exs` directly, since `config/test.exs` configures Oban
  for the suite, and installs the shipped bounds for the comparison: the test
  environment shortens the extraction budget to seconds, which would hold the
  window above a ceiling no deployment runs under.

  `async: false`: the application environment it installs is shared by the
  whole VM.
  """
  use Doctrans.EnvCase, async: false

  alias Doctrans.Jobs.{DocumentExtractionJob, EmbeddingJob, LlmProcessingJob}
  alias Doctrans.TestEnv

  @jobs [DocumentExtractionJob, LlmProcessingJob, EmbeddingJob]
  @bounded_sections [:pdf_extraction, :document_conversion, :openai, :embedding]

  setup do
    config =
      Path.expand("../../config/config.exs", __DIR__)
      |> Config.Reader.read!(env: :prod)

    for section <- @bounded_sections do
      TestEnv.put_env(section, Keyword.fetch!(config[:doctrans], section))
    end

    %{oban: Keyword.fetch!(config[:doctrans], Oban)}
  end

  test "the rescue window is wider than every job's ceiling with the shipped bounds", %{
    oban: oban
  } do
    rescue_after = rescue_after(oban)
    job = %Oban.Job{args: %{}}

    for worker <- @jobs do
      ceiling = worker.timeout(job)

      assert is_integer(ceiling) and ceiling > 0,
             "#{inspect(worker)} must bound its attempts, or a hung one holds its queue"

      assert rescue_after > ceiling,
             "#{inspect(worker)} may run for #{ceiling} ms, past the #{rescue_after} ms rescue " <>
               "window, so a healthy run could be rescued as an orphan"
    end
  end

  defp rescue_after(oban) do
    {Oban.Lifeline, opts} =
      oban
      |> Keyword.fetch!(:plugins)
      |> Enum.find(&match?({Oban.Lifeline, _opts}, &1))

    opts |> Keyword.fetch!(:rescue_after) |> Oban.Period.to_milliseconds()
  end
end
