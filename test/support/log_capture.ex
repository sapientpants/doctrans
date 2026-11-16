defmodule Doctrans.LogCapture do
  @moduledoc """
  Captures the `:info` log lines a function emits.

  The suite runs Logger at `:warning`, so an `:info` line is only readable with
  the level raised for the duration of the capture. A per-process level cannot
  raise it: it only narrows what the primary level already lets through. The
  primary level is VM-wide, so a test that captures through here is
  `async: false`.
  """

  import ExUnit.CaptureLog

  @doc "Runs `fun` with Logger at `:info` and returns what it logged."
  @spec capture_info_log((-> any())) :: String.t()
  def capture_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
