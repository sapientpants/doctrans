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
      completed_steps(pages) / (total_pages * 2) * 100.0
    end
  end

  defp completed_steps(pages) do
    Enum.reduce(pages, 0, fn page, acc ->
      acc + step(page.extraction_status) + step(page.translation_status)
    end)
  end

  defp step("completed"), do: 1
  defp step(_status), do: 0
end
