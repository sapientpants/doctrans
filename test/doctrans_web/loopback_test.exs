defmodule DoctransWeb.LoopbackTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.Loopback

  test "admits the IPv4 loopback block, ::1 and their IPv4-mapped form" do
    for address <- [
          {127, 0, 0, 1},
          {127, 255, 0, 9},
          {0, 0, 0, 0, 0, 0, 0, 1},
          # ::ffff:127.0.0.1, as a listener bound on `::` sees it
          {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
        ] do
      assert Loopback.loopback?(address), "#{inspect(address)} was refused"
    end
  end

  test "refuses every other address, and no address at all" do
    for address <- [
          {192, 168, 1, 20},
          {172, 17, 0, 1},
          {0, 0, 0, 0},
          {128, 0, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 0},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          # ::ffff:192.168.1.20
          {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0114},
          nil
        ] do
      refute Loopback.loopback?(address), "#{inspect(address)} was admitted"
    end
  end
end
