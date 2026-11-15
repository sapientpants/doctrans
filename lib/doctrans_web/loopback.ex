defmodule DoctransWeb.Loopback do
  @moduledoc """
  Whether a peer address is this machine's loopback interface.

  Shared by `DoctransWeb.Plugs.LoopbackOnly`, which checks `conn.remote_ip`,
  and `DoctransWeb.Live.Hooks.LoopbackOnly`, which checks the socket's
  `:peer_data`, so the HTTP render and the socket admit exactly the same peers.
  """

  import Bitwise, only: [>>>: 2]

  @doc """
  Whether `address` is a loopback address: `127.0.0.0/8`, `::1`, or the
  IPv4-mapped form of the former, which is how a listener bound on `::` sees
  an IPv4 loopback client. Anything else, `nil` included, is not.
  """
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, high, _low}), do: high >>> 8 == 127
  def loopback?(_address), do: false
end
