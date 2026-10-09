defmodule ElixirSSI.Command.AuthTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.Auth

  test "launch tickets are unguessable, single use, and do not consume on a failed guess" do
    token = Auth.ticket()
    assert byte_size(token) >= 40
    refute Auth.consume_ticket("wrong")
    assert Auth.consume_ticket(token)
    refute Auth.consume_ticket(token)
  end

  test "expired tickets cannot establish authority" do
    token = Auth.ticket()
    path = Path.join(ElixirSSI.Command.Store.directory(), "browser-ticket.json")
    record = Jason.decode!(File.read!(path)) |> Map.put("expires", 0)
    File.write!(path, Jason.encode!(record))
    refute Auth.consume_ticket(token)
  end
end
