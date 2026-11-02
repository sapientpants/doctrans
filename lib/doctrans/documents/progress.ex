defmodule Doctrans.Documents.Progress do
  @moduledoc """
  Pure progress calculation from loaded page statuses. Never loads associations
  or queries the database; callers must supply a list of pages explicitly.

  `from_counts/3` is the one definition: `calculate/2` counts the completed
  steps of a page list and hands them over, and
  `Doctrans.Documents.ProcessingStatus` hands over the counts its own query
  returns, so the dashboard card and the viewer cannot disagree about what a
  percentage means.
  """

  @type page_status :: %{
          required(:extraction_status) => String.t(),
          required(:translation_status) => String.t(),
          optional(atom()) => term()
        }

  @spec calculate([page_status()], non_neg_integer() | nil) :: float()
  def calculate(pages, total_pages) when is_list(pages) do
    from_counts(
      Enum.count(pages, &(&1.extraction_status == "completed")),
      Enum.count(pages, &(&1.translation_status == "completed")),
      total_pages
    )
  end

  @doc """
  Progress as a percentage of the steps a document owes: two per expected page,
  one extraction and one translation.

  A document that has not counted its pages yet has no denominator, so it reads
  as zero rather than as finished.
  """
  @spec from_counts(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) :: float()
  def from_counts(_extracted, _translated, total_pages) when total_pages in [nil, 0], do: 0.0

  def from_counts(extracted, translated, total_pages) do
    (extracted + translated) / (total_pages * 2) * 100.0
  end
end
