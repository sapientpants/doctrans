defmodule Doctrans.Documents.Topics do
  @moduledoc """
  Subscriptions and broadcasts for document and dashboard updates.

  Two topics carry everything. The per-document topic (`document:<id>`) is what a
  viewer subscribes to; the collection topic (`documents`) is what the dashboard
  subscribes to, once, for the whole list. Most events go to both.

  Payloads follow one rule: an event about a row that still exists carries the
  struct, so a subscriber that only needs to re-render has it in hand, and an
  event about a row that is gone carries the bare id, because a struct would only
  be a stale copy of something no longer there. Subscribers that need more than
  the payload re-query -- the dashboard always does.
  """

  require Logger

  alias Doctrans.Documents.{Document, Page}

  @documents_topic "documents"

  @doc """
  Subscribes to updates for all documents (for dashboard).
  """
  @spec subscribe_documents() :: :ok | {:error, term()}
  def subscribe_documents do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, @documents_topic)
  end

  @doc """
  Unsubscribes from updates for all documents.
  """
  @spec unsubscribe_documents() :: :ok
  def unsubscribe_documents do
    Phoenix.PubSub.unsubscribe(Doctrans.PubSub, @documents_topic)
  end

  @doc """
  Subscribes to updates for a specific document.
  """
  @spec subscribe_document(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_document(document_id) do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, document_topic(document_id))
  end

  @spec unsubscribe_document(Ecto.UUID.t()) :: :ok
  def unsubscribe_document(document_id) do
    Phoenix.PubSub.unsubscribe(Doctrans.PubSub, document_topic(document_id))
  end

  @doc """
  Broadcasts a document creation event.

  The collection topic only: a document nobody is viewing yet has no per-document
  subscribers. Carries the struct, per the payload rule in the moduledoc -- the
  row exists.
  """
  @spec broadcast_document_created(Document.t()) :: :ok
  def broadcast_document_created(%Document{} = document) do
    Logger.debug("Broadcasting document_created for #{document.id} to the collection topic")

    # Dashboards watch the collection topic so another tab's upload appears
    broadcast_collection({:document_created, document})
  end

  @doc """
  Broadcasts a document update event to the document's viewers and to dashboards.
  """
  @spec broadcast_document_updated(Document.t()) :: :ok
  def broadcast_document_updated(%Document{} = document) do
    Logger.debug("Broadcasting document_updated for #{document.id} to both topics")

    fan_out(document.id, {:document_updated, document})
  end

  @doc """
  Broadcasts a document deletion event to the document's viewers and to dashboards.

  Carries the bare id, per the payload rule in the moduledoc -- the row is gone.
  """
  @spec broadcast_document_deleted(Document.t()) :: :ok
  def broadcast_document_deleted(%Document{} = document) do
    Logger.debug("Broadcasting document_deleted for #{document.id} to both topics")

    fan_out(document.id, {:document_deleted, document.id})
  end

  @doc """
  Broadcasts a page update event to the document's viewers and to dashboards.
  """
  @spec broadcast_page_updated(Page.t()) :: :ok
  def broadcast_page_updated(%Page{} = page) do
    Logger.debug(
      "Broadcasting page_updated for page #{page.page_number} of document #{page.document_id}"
    )

    fan_out(page.document_id, {:page_updated, page})
  end

  # Every event except creation goes to both topics: the document's own, for a
  # viewer with it open, and the collection, for the dashboards listing it.
  defp fan_out(document_id, message) do
    _ = Phoenix.PubSub.broadcast(Doctrans.PubSub, document_topic(document_id), message)
    broadcast_collection(message)
  end

  # The broadcast result is discarded deliberately. `Phoenix.PubSub.broadcast/3`
  # reports only a failure to reach the local registry, which a caller in the
  # middle of a database write can do nothing about, and no caller here is in a
  # position to retry. Every broadcast function returns a plain `:ok` so that
  # none of them invites a caller to assert on something that cannot vary.
  defp broadcast_collection(message) do
    _ = Phoenix.PubSub.broadcast(Doctrans.PubSub, @documents_topic, message)
    :ok
  end

  defp document_topic(document_id), do: "document:#{document_id}"
end
