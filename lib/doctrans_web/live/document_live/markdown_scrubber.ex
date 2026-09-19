defmodule DoctransWeb.DocumentLive.MarkdownScrubber do
  @moduledoc """
  HTML scrubber for rendered Markdown: `HtmlSanitizeEx.basic_html/1` plus table
  column alignment.

  `HtmlSanitizeEx.Scrubber.BasicHTML` allows `table`, `thead`, `tbody`, `tr`,
  `th` and `td` but strips *every* attribute from them. Comrak (via MDEx) encodes
  a GFM table's alignment row as `align="left" | "center" | "right"` on each cell,
  so alignment is discarded before it reaches the page. OCR'd tables are largely
  numeric, where a right-aligned column is part of the information the source
  document carried, so alignment is preserved here.

  This module extends `:basic_html` rather than restating it, so the allowed tag
  and attribute set is exactly the one `HtmlSanitizeEx.basic_html/1` permits.
  The only addition is `align` on `th`/`td`, restricted to the three literal
  values comrak emits — `allow_tag_with_this_attribute_values/3` matches on the
  value, so anything else (including `justify` or a CSS expression) is dropped.
  The restriction is on the value alone: the parser lowercases attribute names
  and decodes entities before that match runs, so `ALIGN="right"` and
  `align="&#114;ight"` both survive as `align="right"`. That carries no payload —
  `align` takes no URL and no CSS — and every other attribute, including an
  `onload` smuggled alongside it, is resolved against `BasicHTML` as before.

  Extending alone is not enough: the generated fallback would hand `th`/`td`
  nodes to `BasicHTML.scrub/1`, which resolves attributes against *its* rules.
  Re-declaring both tags here registers them locally so their attributes are
  resolved against the clauses below first, then fall back to `BasicHTML`.
  """

  use HtmlSanitizeEx, extend: :basic_html

  @alignments ["left", "center", "right"]

  allow_tag_with_these_attributes("th", [])
  allow_tag_with_these_attributes("td", [])

  allow_tag_with_this_attribute_values("th", "align", @alignments)
  allow_tag_with_this_attribute_values("td", "align", @alignments)
end
