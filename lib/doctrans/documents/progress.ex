defmodule Doctrans.Documents.Progress do
  @moduledoc """
  Pure progress calculation from loaded page statuses. Never loads associations
  or queries the database; callers must supply a list of pages explicitly.
  """

  @type page_status :: %{
          required(:extraction_status) => String.t(),
          required(:translation_status) => String.t(),
          optional(atom()) => term()
        }

  @spec calculate([page_status()], non_neg_integer() | nil) :: float()
  def calculate(pages, total_pages) when is_list(pages) do
    if pages == [] or total_pages in [nil, 0] do
      0.0
    else
      completed_steps =
        Enum.reduce(pages, 0, fn page, acc ->
          extraction_done = if page.extraction_status == "completed", do: 1, else: 0
          translation_done = if page.translation_status == "completed", do: 1, else: 0
          acc + extraction_done + translation_done
        end)

      completed_steps / (total_pages * 2) * 100.0
    end
  end
end
