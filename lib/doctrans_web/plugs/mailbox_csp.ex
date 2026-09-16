defmodule DoctransWeb.Plugs.MailboxCsp do
  @moduledoc """
  Gives the dev-only Swoosh mailbox preview the CSP nonce its template renders.

  The preview's template emits one inline `<script>` carrying
  `nonce="<%= csp_nonce(@conn, :script) %>"`, and `Plug.Swoosh.MailboxPreview`
  reads that nonce out of `conn.assigns` under keys taken from the forward's
  options, which default to `:script_csp_nonce` and `:style_csp_nonce`. Nothing
  assigned either, so the attribute rendered as the empty string -- the
  template is EEx, which stringifies `nil`, rather than HEEx, which drops the
  attribute -- and an empty nonce matches no source, so `script-src 'self'`
  refuses the script. That is the timestamps, the text-body toggle and the
  link handling in the preview, all failing with nothing on the server.

  This plug mints one nonce per request, assigns it, and replaces the response
  policy with `DoctransWeb.ContentSecurityPolicy.mailbox/1` -- the base policy
  plus that nonce in `script-src`, and nothing else.

  Two details are deliberate:

  Swoosh defaults these keys to `:script_csp_nonce` and `:style_csp_nonce`, so
  a plug publishing under the defaults would work even if the forward named no
  keys at all. `assign_keys/0` names its own instead, so the forward has to
  pass them and the pairing stays visible.

  Only `:script` is named. Swoosh merges what it is given into its own defaults,
  so the absent `:style` keeps pointing at `:style_csp_nonce`, which nothing
  assigns, and the preview's stylesheet `<link>` keeps an empty nonce -- inert,
  because `style-src 'self'` admits that same-origin file already. It is not
  this defect in miniature, and the policy is not widened to cover it.

  The forward serves everything under `/dev/mailbox`, so the widened header
  reaches the framed email bodies at `/dev/mailbox/:id/html` too. A nonce
  admits only elements that carry it, and those documents are rendered by
  Swoosh from email HTML without one, so nothing in them is admitted by it.
  """
  @behaviour Plug

  import Plug.Conn

  alias DoctransWeb.ContentSecurityPolicy

  @assign_key :mailbox_csp_nonce

  @doc """
  The assign keys the nonce is published under, in the shape Swoosh wants.

  The forward passes this to `Plug.Swoosh.MailboxPreview`'s
  `:csp_nonce_assign_key` rather than repeating the atom, so the two sides
  cannot drift into the empty-nonce state this plug exists to prevent. It is a
  map, not the bare atom `live_dashboard` accepts: Swoosh pipes the option
  through `Enum.into/2`, which raises on an atom.
  """
  def assign_keys, do: %{script: @assign_key}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = ContentSecurityPolicy.nonce()

    conn
    |> assign(@assign_key, nonce)
    |> put_resp_header("content-security-policy", ContentSecurityPolicy.mailbox(nonce))
  end
end
