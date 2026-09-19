defmodule DoctransWeb.PrivacyCopy do
  @moduledoc """
  Copy describing where document content is processed.

  The interface used to promise, unconditionally, that documents never leave the
  device. That promise holds only when every inference endpoint runs on this
  machine, which is a configuration fact rather than a property of the app --
  see `Doctrans.Config.Inference`. Each claim therefore comes in two forms: the
  local promise, and a remote form naming the destination.

  The pairs live here rather than inline at their call sites for two reasons.
  Keeping a claim and its replacement side by side makes it hard to soften one
  and leave its twin overclaiming, which is the failure this module exists to
  prevent. And the local strings are reused verbatim, so their existing
  translations across the ten non-English locales stay valid -- rewording a
  msgid would mark every translation fuzzy and fail the translation gate.

  What gets interpolated is `Doctrans.Config.Inference.destination_label/0`:
  the host, or — for an endpoint whose host cannot be parsed — the configured
  URL itself, which is the only thing left to name. Never an API key, and never
  credentials: a configured URL may carry them in its userinfo or its query, and
  `Doctrans.Config.Inference.redact_url/1` strips both before any value reaches
  this module.
  """

  use Gettext, backend: DoctransWeb.Gettext

  alias Doctrans.Config.Inference

  @doc """
  The dashboard subtitle under the application title.
  """
  @spec tagline() :: String.t()
  def tagline do
    if Inference.local?() do
      gettext("Private document translation powered by local AI")
    else
      gettext("Document translation powered by AI on %{host}", host: destination())
    end
  end

  @doc """
  The empty state shown when no documents have been uploaded yet.
  """
  @spec empty_state() :: String.t()
  def empty_state do
    if Inference.local?() do
      gettext("Upload a document to get started. All processing happens locally on your device.")
    else
      gettext(
        "Upload a document to get started. Document content is sent to %{host} for processing.",
        host: destination()
      )
    end
  end

  @doc """
  The note beneath the file picker in the upload modal.
  """
  @spec upload_notice() :: String.t()
  def upload_notice do
    if Inference.local?() do
      gettext("Your documents never leave your device")
    else
      gettext("Documents are sent to %{host} for processing", host: destination())
    end
  end

  @doc """
  The icon that accompanies `upload_notice/0`.

  A closed padlock states a guarantee, so it may only appear beside the local
  promise; remote processing gets an outbound arrow instead.
  """
  @spec upload_notice_icon() :: String.t()
  def upload_notice_icon do
    if Inference.local?(), do: "hero-lock-closed", else: "hero-arrow-up-tray"
  end

  defp destination, do: Inference.destination_label()
end
