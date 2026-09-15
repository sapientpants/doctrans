defmodule DoctransWeb.DocumentLive.UploadComponents do
  @moduledoc """
  The upload dialog and the per-file feedback it renders.
  """
  use DoctransWeb, :html

  alias DoctransWeb.DocumentLive.UploadIntake
  alias DoctransWeb.ErrorMessages
  alias DoctransWeb.PrivacyCopy

  import DoctransWeb.DocumentLive.Components, only: [language_name: 1]

  @doc """
  Renders the upload modal dialog.
  """
  attr :uploads, :map, required: true
  attr :target_language, :string, required: true

  attr :failures, :list,
    default: [],
    doc: "files that did not reach the processing queue, as %{name:, message:} maps"

  attr :pending, :list,
    default: [],
    doc: "names of files still uploading when the submission was reported"

  attr :started, :integer, default: 0, doc: "documents the same submission did queue"

  attr :return_focus, :string,
    required: true,
    doc: "selector for the control that opened the dialog, owned by the caller"

  def upload_modal(assigns) do
    ~H"""
    <.dialog
      id="upload-modal"
      title_id="upload-modal-title"
      on_close="hide_upload_modal"
      return_focus={@return_focus}
      class="modal modal-open"
      box_class="modal-box max-w-lg"
      close_class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
      backdrop_class="modal-backdrop bg-black/50"
    >
      <h3 id="upload-modal-title" class="font-bold text-lg mb-4">
        {gettext("Upload New Document")}
      </h3>

      <form phx-submit="upload_document" phx-change="validate_upload" id="upload-form">
        <div class="form-control mb-4">
          <label id="upload-files-label" for={@uploads.document.ref} class="label">
            <span class="label-text">{gettext("Documents")}</span>
          </label>
          <%!-- `sr-only` clips the input rather than removing it. Under `hidden` it was
                  `display:none`, which takes it out of both the accessibility tree and the
                  tab order: the `browse` and `+ Add more files` labels below are the only
                  other way in, and a `<label>` is not focusable, so there was no
                  keyboard-only path to choosing a file at all. Focus is visible because the
                  drop zone is the input's peer and draws the ring for it.

                  `aria-labelledby` names the input from the `Documents` label alone. Those
                  two proxy labels also point `for` at this input, and every label that
                  targets a control is concatenated into its name; the explicit reference
                  wins over all of them. --%>
          <div class="relative">
            <.live_file_input
              upload={@uploads.document}
              class="sr-only peer"
              aria-labelledby="upload-files-label"
              aria-describedby={if(@uploads.document.entries == [], do: "upload-files-hint")}
            />
            <div
              class={[
                "border-2 border-dashed border-base-300 rounded-lg p-4 text-center",
                "transition-colors hover:border-primary",
                "peer-focus-visible:border-primary peer-focus-visible:ring-2",
                "peer-focus-visible:ring-primary/30"
              ]}
              phx-drop-target={@uploads.document.ref}
            >
              <.upload_empty_state
                :if={@uploads.document.entries == []}
                upload={@uploads.document}
              />
              <.upload_entries_list
                :if={@uploads.document.entries != []}
                upload={@uploads.document}
              />
              <.upload_error :for={err <- upload_errors(@uploads.document)} error={err} />
            </div>
          </div>
          <.upload_outcomes
            :if={@failures != [] or @pending != []}
            failures={@failures}
            pending={@pending}
            started={@started}
          />
        </div>

        <div class="form-control mb-6">
          <label for="target-lang-select" class="label">
            <span class="label-text">{gettext("Target Language")}</span>
          </label>
          <select
            name="target_language"
            class="select select-bordered w-full"
            id="target-lang-select"
            phx-hook="EscapeStaysInSelect"
          >
            <.language_options selected={@target_language} />
          </select>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="hide_upload_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            class="btn btn-primary"
            disabled={submit_blocked?(@uploads.document)}
            id="start-translation-btn"
          >
            {gettext("Start Translation")}
          </button>
        </div>
      </form>
    </.dialog>
    """
  end

  defp upload_empty_state(assigns) do
    ~H"""
    <div class="py-4">
      <.icon name="hero-cloud-arrow-up" class="w-12 h-12 mx-auto text-base-content/50" />
      <p class="mt-2 text-sm text-base-content/70">
        {gettext("Drag and drop documents here, or")}
        <label for={@upload.ref} class="link link-primary cursor-pointer">
          {gettext("browse")}
        </label>
      </p>
      <%!-- Named by the file input's `aria-describedby`, so the accepted formats and
            the file limit are read out with the control rather than after it. The
            reference is conditional on this state: the hint goes away with the empty
            state once files are picked. --%>
      <p id="upload-files-hint" class="mt-1 text-xs text-base-content/50">
        {gettext("PDF, Word (.docx, .doc), Rich Text (.rtf), OpenDocument (.odt) - Up to 10 files")}
      </p>
      <p id="upload-privacy-notice" class="mt-2 text-xs text-base-content/40">
        <.icon
          name={PrivacyCopy.upload_notice_icon()}
          class="w-3 h-3 inline-block align-text-top"
        />
        {PrivacyCopy.upload_notice()}
      </p>
    </div>
    """
  end

  defp upload_entries_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <div
        :for={entry <- @upload.entries}
        class={[
          "flex items-center gap-2 rounded-lg p-2",
          if(entry.valid?, do: "bg-base-200", else: "bg-error/10 ring-1 ring-error/30")
        ]}
      >
        <.icon name="hero-document" class="w-6 h-6 text-primary shrink-0" />
        <div class="flex-1 text-left min-w-0">
          <p class="text-sm font-medium truncate">{entry.client_name}</p>
          <%!-- The reason sits on the file it belongs to. Without this a rejected
                entry is explained nowhere: the config-level list below carries only
                errors that belong to the whole upload, never to one entry. --%>
          <p
            :for={err <- upload_errors(@upload, entry)}
            class="text-error text-xs mt-1"
            data-entry-error={entry.ref}
          >
            {ErrorMessages.message(UploadIntake.entry_reason([err], entry))}
          </p>
          <progress
            :if={entry.valid?}
            class="progress progress-primary w-full h-1"
            value={entry.progress}
            max="100"
          />
        </div>
        <%!-- The name carries the filename: the list repeats this button once per
              entry, and "Remove" on its own does not say which file goes. --%>
        <button
          type="button"
          phx-click="cancel_upload"
          phx-value-ref={entry.ref}
          aria-label={gettext("Remove %{file}", file: entry.client_name)}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      <label
        for={@upload.ref}
        class="block text-xs text-base-content/50 cursor-pointer hover:text-primary mt-2"
      >
        {gettext("+ Add more files")}
      </label>
    </div>
    """
  end

  attr :selected, :string, required: true

  defp language_options(assigns) do
    # Codes come from the canonical translation-target list and names from
    # `language_name/1`, so neither is spelled out twice. Sorting is by the
    # translated name, so the order follows the interface language.
    languages =
      Doctrans.Languages.supported()
      |> Enum.map(&{&1, language_name(&1)})
      |> Enum.sort_by(fn {_code, name} -> name end)

    assigns = assign(assigns, :languages, languages)

    ~H"""
    <option :for={{code, name} <- @languages} value={code} selected={code == @selected}>
      {name}
    </option>
    """
  end

  # A submission that would be cancelled wholesale is not worth offering. Without
  # `auto_upload`, `phx-submit` runs the `allow_upload` preflight first, and one
  # entry in error fails it for the whole config -- LiveView then cancels *every*
  # entry, so a good file picked beside an oversized one is discarded with it and
  # the server never hears about either. The button stays disabled until the user
  # has removed what the per-entry errors point at.
  defp submit_blocked?(upload) do
    upload.entries == [] or upload_errors(upload) != [] or
      Enum.any?(upload.entries, &(not &1.valid?))
  end

  # Server-side outcomes, one line per file. The modal stays open to show them, and
  # it covers the flash toasts (z-999 against z-50), so what the submission did start
  # is reported in here as well rather than only in a flash nobody can see yet.
  defp upload_outcomes(assigns) do
    ~H"""
    <div id="upload-outcomes" aria-live="polite" class="mt-3 space-y-2 text-left">
      <div :if={@started > 0} id="upload-started" class="alert alert-success items-start">
        <.icon name="hero-check-circle" class="size-5 shrink-0" />
        <p class="text-sm flex-1">{upload_started_message(@started)}</p>
      </div>

      <div :if={@failures != []} id="upload-failures" class="alert alert-error items-start">
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div class="flex-1 min-w-0">
          <p class="font-semibold text-sm">
            {ngettext(
              "This file was not uploaded",
              "These files were not uploaded",
              length(@failures)
            )}
          </p>
          <ul class="mt-1 space-y-1 max-h-40 overflow-y-auto">
            <li :for={failure <- @failures} class="text-sm" data-failed-upload={failure.name}>
              <span class="font-medium break-all">{failure.name}</span>: {failure.message}
            </li>
          </ul>
        </div>
      </div>

      <%!-- Reported rather than dropped: a file still in flight when the submission
            was accounted for would otherwise vanish from a modal that closed on the
            strength of the files beside it. --%>
      <div :if={@pending != []} id="upload-pending" class="alert alert-info items-start">
        <.icon name="hero-arrow-path" class="size-5 shrink-0" />
        <div class="flex-1 min-w-0">
          <p class="font-semibold text-sm">
            {ngettext(
              "This file is still uploading. Submit again to finish it.",
              "These files are still uploading. Submit again to finish them.",
              length(@pending)
            )}
          </p>
          <ul class="mt-1 space-y-1 max-h-40 overflow-y-auto">
            <li :for={name <- @pending} class="text-sm break-all" data-pending-upload={name}>
              {name}
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The message for documents a submission queued for processing.

  Shared so the dashboard flash and the modal's own outcome list cannot drift apart.
  """
  @spec upload_started_message(non_neg_integer()) :: String.t()
  def upload_started_message(count) do
    ngettext(
      "Document uploaded! Processing will begin shortly.",
      "%{count} documents uploaded! Processing will begin shortly.",
      count
    )
  end

  defp upload_error(assigns) do
    ~H"""
    <p class="text-error text-sm mt-2">
      {error_to_string(@error)}
    </p>
    """
  end

  # Config-level errors only: `upload_errors/1` never returns an entry's own errors,
  # and those go through `UploadIntake.entry_reason/2` so that the browser's
  # rejection and the server's are worded by the same `ErrorMessages` clause.
  defp error_to_string(:too_many_files) do
    gettext("Maximum %{max} files can be uploaded at once", max: UploadIntake.max_entries())
  end

  # Never `inspect/1` the term: it is rendered to the user, and a LiveView internal
  # is not a sentence.
  defp error_to_string(_err), do: ErrorMessages.message(:upload_failed)
end
