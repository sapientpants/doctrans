defmodule Doctrans.Documents.Topics do
  @moduledoc "Subscriptions and broadcasts for document and dashboard updates."

  require Logger

  alias Doctrans.Documents.{Document, Page}

  @doc """
  Subscribes to updates for all documents (for dashboard).
  """
  @spec subscribe_documents() :: :ok | {:error, term()}
  def subscribe_documents do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, "documents")
  end

  @doc """
  Subscribes to updates for a specific document.
  """
  @spec subscribe_document(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_document(document_id) do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, "document:#{document_id}")
  end

  @spec unsubscribe_document(Ecto.UUID.t()) :: :ok
  def unsubscribe_document(document_id) do
    Phoenix.PubSub.unsubscribe(Doctrans.PubSub, "document:#{document_id}")
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
        "document:#{document.id}",
        {:document_updated, document}
      )

    # Also broadcast to general documents topic (for dashboard)
    _ = Phoenix.PubSub.broadcast(Doctrans.PubSub, "documents", {:document_updated, document})
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
        "document:#{page.document_id}",
        {:page_updated, page}
      )

    # Also broadcast to general documents topic (for dashboard progress)
    _ = Phoenix.PubSub.broadcast(Doctrans.PubSub, "documents", {:page_updated, page})

    :ok
  end
end
