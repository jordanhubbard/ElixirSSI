defmodule SSI.SSHExecTest do
  use ExUnit.Case, async: true

  test "SSH exec evaluates Elixir and reports errors" do
    assert {:ok, "42"} = SSI.SSH.exec(~c"6 * 7", ~c"root", {{127, 0, 0, 1}, 1234})
    assert {:error, _} = SSI.SSH.exec(~c"raise \"failed\"", ~c"root", {{127, 0, 0, 1}, 1234})
    assert {:error, _} = SSI.SSH.exec(~c"def broken(", ~c"root", {{127, 0, 0, 1}, 1234})
  end

  test "SSH exec refuses oversized commands" do
    assert {:error, "Elixir command exceeds 1 MiB"} = SSI.SSH.exec(String.duplicate("x", 1_048_577), ~c"root", nil)
  end
end
