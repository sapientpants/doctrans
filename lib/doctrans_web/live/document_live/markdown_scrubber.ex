defmodule DoctransWeb.DocumentLive.MarkdownScrubber do
  @moduledoc ~S"""
  HTML scrubber for rendered Markdown: `HtmlSanitizeEx.basic_html/1` plus table
  column alignment, an explicit policy for where a link may point, and a
  same-origin rule for images.

  This module extends `:basic_html` rather than restating it, so the allowed tag
  and attribute set is exactly the one `HtmlSanitizeEx.basic_html/1` permits,
  with the three departures below. Every other tag and attribute, including an
  `onload` smuggled alongside an allowed one, is resolved against `BasicHTML`.

  Extending alone is not enough for any of them: the generated fallback hands an
  unregistered node to `BasicHTML.scrub/1`, which resolves its attributes
  against *its* rules. Re-declaring a tag here registers it locally, so its
  attributes are resolved against the clauses in this module first and fall back
  to `BasicHTML` for the rest.

  ## Table cell alignment

  `HtmlSanitizeEx.Scrubber.BasicHTML` allows `table`, `thead`, `tbody`, `tr`,
  `th` and `td` but strips *every* attribute from them. Comrak (via MDEx) encodes
  a GFM table's alignment row as `align="left" | "center" | "right"` on each cell,
  so alignment is discarded before it reaches the page. OCR'd tables are largely
  numeric, where a right-aligned column is part of the information the source
  document carried, so alignment is preserved here.

  The addition is `align` on `th`/`td`, restricted to the three literal values
  comrak emits — `allow_tag_with_this_attribute_values/3` matches on the value,
  so anything else (including `justify` or a CSS expression) is dropped. The
  restriction is on the value alone: the parser lowercases attribute names and
  decodes entities before that match runs, so `ALIGN="right"` and
  `align="&#114;ight"` both survive as `align="right"`. That carries no payload —
  `align` takes no URL and no CSS.

  ## Links

  Everything rendered through this scrubber is written by a party the app does
  not trust: the OCR and translation models, the chat model, and whoever wrote
  the uploaded document. `BasicHTML` keeps an `href` whose scheme is `http`,
  `https` or `mailto`, or which has no scheme at all, and strips every other
  attribute, so nothing distinguished a link that leaves the app from one that
  stays. A prompt-injected answer could present `[open the source document]`
  pointing at a phishing page as an ordinary in-app link.

  The policy is decided here, after `BasicHTML` has run:

    * A target with a scheme leaves the app. It keeps its `href` and gains
      `rel="noreferrer nofollow"` (no `Referer`, and `noreferrer` implies
      `noopener`) and a `data-external` marker that `assets/css/app.css` turns
      into a visible cue. Those two attributes cannot be supplied by the content
      itself: `BasicHTML` strips them on the way in, so their presence means this
      module put them there.
    * A target with neither scheme nor host is same-origin — a page, an anchor,
      or the `""` that MDEx leaves behind when it blanks a dangerous scheme — and
      is left exactly as it was.
    * A scheme-relative target (`//evil.test/x`) passes `BasicHTML`, which only
      checks the scheme, but resolves to *another* origin under the app's own
      scheme. It is the one way to leave the app without a scheme to mark, so the
      `href` is dropped and the anchor stays as text, which is what `BasicHTML`
      already does with a disallowed scheme. Browsers accept a backslash for
      either slash in a URL that resolves against an `http(s)` base, so `\\host`
      and `/\host` are treated the same way.

  ## Images

  `BasicHTML` allows `<img src>` for `http` and `https`. The page's CSP
  (`img-src 'self' data: blob:`) already refuses to fetch those, so a remote
  image is never a zero-click beacon in the viewer; the scrubber is the first
  layer and the CSP the second, and this keeps the first one honest on its own.
  A `src` survives only when it is same-origin by the rule above, so a remote or
  scheme-relative source is dropped and the `<img>` stays, with its `alt`, as the
  broken image it would have been anyway.
  """

  use HtmlSanitizeEx, extend: :basic_html

  alias HtmlSanitizeEx.Scrubber.BasicHTML

  @alignments ["left", "center", "right"]
  @external_rel "noreferrer nofollow"

  # Registered locally so their attributes are resolved here first; see moduledoc.
  allow_tag_with_these_attributes("a", [])
  allow_tag_with_these_attributes("img", [])
  allow_tag_with_these_attributes("th", [])
  allow_tag_with_these_attributes("td", [])

  allow_tag_with_this_attribute_values("th", "align", @alignments)
  allow_tag_with_this_attribute_values("td", "align", @alignments)

  def scrub_attribute("img", {"src", value}) do
    with {"src", src} <- BasicHTML.scrub_attribute("img", {"src", value}),
         :same_origin <- target(src) do
      {"src", src}
    else
      _ -> nil
    end
  end

  # The `href` policy needs the whole attribute list, not one attribute at a
  # time: the marker is added next to the `href`, after `BasicHTML` has decided
  # whether the `href` survives at all.
  def scrub_attributes("a", attributes) do
    attributes
    |> Enum.map(&scrub_attribute("a", &1))
    |> Enum.reject(&is_nil/1)
    |> apply_link_policy()
  end

  defp apply_link_policy(attributes) do
    case List.keyfind(attributes, "href", 0) do
      nil ->
        attributes

      {"href", href} ->
        case target(href) do
          :same_origin ->
            attributes

          :external ->
            attributes ++ [{"rel", @external_rel}, {"data-external", ""}]

          :scheme_relative ->
            List.keydelete(attributes, "href", 0)
        end
    end
  end

  # Where a target the scrubber has already accepted will take the browser.
  # `URI.parse/1` never raises; a target it cannot make sense of still has no
  # scheme and no host, which is the same-origin case, and the browser would
  # resolve it against the page either way.
  defp target(target) do
    cond do
      scheme_relative?(target) ->
        :scheme_relative

      match?(%URI{scheme: nil, host: nil}, URI.parse(target)) ->
        :same_origin

      true ->
        :external
    end
  end

  # Two leading slashes, either of which may be a backslash: the URL standard's
  # "relative slash" state treats `\` as `/` when the base is `http(s)`, so
  # `\\evil.test` and `/\evil.test` both land on `//evil.test`.
  defp scheme_relative?(<<first, second, _::binary>>)
       when first in [?/, ?\\] and second in [?/, ?\\],
       do: true

  defp scheme_relative?(_target), do: false
end
