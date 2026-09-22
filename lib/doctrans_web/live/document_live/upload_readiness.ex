defmodule DoctransWeb.DocumentLive.UploadReadiness do
  @moduledoc """
  Tells the user, while the upload dialog is open, what the model servers cannot do.

  A misconfigured model name or a model server that is not running is invisible
  until a document is halfway through processing: the upload succeeds, the
  progress bar moves, and the failure arrives minutes later as a failed page. The
  dialog is the last moment at which the user is still deciding, so it is where
  `Doctrans.Config.Readiness` reports.

  It never blocks the upload. Queued work survives a model server that is down --
  startup recovery and the retry paths exist to resume it -- and a check that was
  merely wrong about a working server would lock the user out of their own
  application. The button stays enabled; only what the user is told changes.

  ## Why the check runs on open rather than on mount

  Two HTTP calls per dashboard visit would be paid by every user who came to read
  a document, and a result fetched at mount goes stale exactly when it matters --
  the user who reads "the model server is not answering", starts it, and comes
  back. Re-checking on each open makes closing and reopening the dialog the
  retry, with no control to explain.

  ## Late results

  `start_async/4` tracks one task per name and drops the result of any task a
  later start superseded, so opening the dialog twice cannot show the older
  answer. Nothing here cancels, so `cancel_async/2`'s trailing-result trap does
  not apply: a result that lands while the dialog is closed writes an assign
  nobody is rendering, and the next open overwrites it with `:checking` before
  its own check reports.
  """
  use DoctransWeb, :html

  import Phoenix.LiveView, only: [start_async: 4]

  alias Doctrans.Config.Readiness
  alias DoctransWeb.ErrorMessages

  require Logger

  @typedoc """
  What the dialog knows about the model settings right now.

  `:idle` is the dashboard before any dialog has opened, `:checking` a probe in
  flight, `:unavailable` a check that crashed rather than reported -- distinct
  from a report of problems, because our own failure to ask is not a finding
  about the user's settings. Anything else is the report itself.
  """
  @type state :: :idle | :checking | :unavailable | Readiness.report()

  @doc "Seeds the assign the dialog renders from."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: assign(socket, :readiness, :idle)

  @doc """
  Starts a fresh check, off the process the user is waiting on.

  Supervised by `Doctrans.TaskSupervisor`, so a model server that never answers
  cannot stall a LiveView that is also serving the document list and its
  progress updates.
  """
  @spec check(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def check(socket) do
    socket
    |> assign(:readiness, :checking)
    |> start_async(:upload_readiness, &Readiness.check/0, supervisor: Doctrans.TaskSupervisor)
  end

  @doc """
  Records what the check found, or that it could not be made.
  """
  @spec resolve(Phoenix.LiveView.Socket.t(), {:ok, Readiness.report()} | {:exit, term()}) ::
          Phoenix.LiveView.Socket.t()
  def resolve(socket, {:ok, report}), do: assign(socket, :readiness, report)

  def resolve(socket, {:exit, reason}) do
    # Bounded: an exit reason carries a stacktrace whose frames can hold the
    # request struct, endpoint URL and API key included.
    Logger.warning("Readiness check crashed: #{inspect(reason, limit: 10, printable_limit: 256)}")

    assign(socket, :readiness, :unavailable)
  end

  @doc """
  Renders what the check found, inside the upload dialog.

  Silent on a ready configuration: the absence of the warning is the all-clear,
  and a dialog that congratulates itself on every open trains the user to skip
  the one place this module ever has something to say.
  """
  attr :readiness, :any, required: true, doc: "a `t:state/0`"

  def readiness_notice(assigns) do
    assigns = assign(assigns, :problems, problems(assigns.readiness))

    ~H"""
    <%!-- The region is rendered from the dialog's first paint, holding the
          checking line, so the problems that replace it are an update to a live
          region rather than a live region inserted with its content already in
          place -- which screen readers are not required to announce. --%>
    <div id="upload-readiness" aria-live="polite">
      <p
        :if={@readiness == :checking}
        id="upload-readiness-checking"
        class="mb-4 flex items-center gap-1.5 text-xs text-base-content/50"
      >
        <.icon name="hero-arrow-path" class="w-3 h-3 animate-spin" />
        {gettext("Checking model availability...")}
      </p>

      <%!-- Said rather than swallowed: without it the checking line disappears
            into nothing, which is what a ready configuration looks like, and the
            user reads a guarantee we never obtained. --%>
      <p
        :if={@readiness == :unavailable}
        id="upload-readiness-unknown"
        class="mb-4 text-xs text-base-content/50"
      >
        {gettext("Could not check whether the model settings will work.")}
      </p>

      <div
        :if={@problems != []}
        id="upload-readiness-problems"
        class="alert alert-warning items-start mb-4"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <div class="flex-1 min-w-0">
          <p class="font-semibold text-sm">
            {gettext("Processing may not finish with the current settings")}
          </p>
          <%!-- Each line carries its own consequence and its own remediation: a
                missing embedding model costs search while translation still
                works, and one heading cannot say that for all of them. --%>
          <ul class="mt-1 space-y-1">
            <li
              :for={{code, _bindings} = problem <- @problems}
              class="text-sm"
              data-readiness-problem={code}
            >
              {ErrorMessages.message(problem)}
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  # Only a report has problems; the three atoms are states of the check itself.
  defp problems(%{problems: problems}), do: problems
  defp problems(_state), do: []
end
