defmodule Doctrans.Documents.Topics do
  @moduledoc "Subscriptions and broadcasts for document and dashboard updates."

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

  Only the collection topic is notified: a document nobody is viewing yet has
  no per-document subscribers.
  """
  @spec broadcast_document_created(Document.t()) :: :ok
  def broadcast_document_created(%Document{} = document) do
    Logger.debug("Broadcasting document_created for #{document.id} to documents topic")

    # Dashboards watch the collection topic so another tab's upload appears
    _ =
      Phoenix.PubSub.broadcast(
        Doctrans.PubSub,
        @documents_topic,
        {:document_created, document}
      )

    :ok
  end

  @doc """
  Broadcasts a document update event.
  """
  @spec broadcast_document_update(Document.t()) :: :ok | {:error, term()}
  def broadcast_document_update(%Document{} = document) do
    Logger.debug("Broadcasting document_updated for #{document.id} to documents topic")

    # Broadcast to specific document topic (for document viewer)
    _ =
      Phoenix.PubSub.broadcast(
        Doctrans.PubSub,
        document_topic(document.id),
        {:document_updated, document}
      )

    # Also broadcast to general documents topic (for dashboard)
    _ =
      Phoenix.PubSub.broadcast(Doctrans.PubSub, @documents_topic, {:document_updated, document})
  end

  @doc """
  Broadcasts a document deletion event.

  Carries the bare document id rather than the struct: the row is gone, so a
  struct would only be a stale copy of it.
  """
  @spec broadcast_document_deleted(Document.t()) :: :ok
  def broadcast_document_deleted(%Document{} = document) do
    Logger.debug("Broadcasting document_deleted for #{document.id} to documents topic")

    # Broadcast to specific document topic (for anyone viewing the document)
    _ =
      Phoenix.PubSub.broadcast(
        Doctrans.PubSub,
        document_topic(document.id),
        {:document_deleted, document.id}
      )

    # Also broadcast to general documents topic (for dashboard)
    _ =
      Phoenix.PubSub.broadcast(
        Doctrans.PubSub,
        @documents_topic,
        {:document_deleted, document.id}
      )

    :ok
  end

  @doc """
  Broadcasts a page update event.
  """
  @spec broadcast_page_update(Page.t()) :: :ok
  def broadcast_page_update(%Page{} = page) do
    Logger.debug(
      "Broadcasting page_updated for page #{page.page_number} of document #{page.document_id}"
    )

    # Broadcast to specific document topic (for document viewer)
    _ =
      Phoenix.PubSub.broadcast(
        Doctrans.PubSub,
        document_topic(page.document_id),
        {:page_updated, page}
      )

    # Also broadcast to general documents topic (for dashboard progress)
    _ = Phoenix.PubSub.broadcast(Doctrans.PubSub, @documents_topic, {:page_updated, page})

    :ok
  end

  defp document_topic(document_id), do: "document:#{document_id}"
end
