defmodule ElixirSSI.Command.OperationsTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.{Operations, Store}

  test "serializes work and retains success after worker completion" do
    parent = self()

    {:ok, id} =
      Operations.submit("controlled", fn ->
        send(parent, {:worker, self()})

        receive do
          :finish -> {:ok, "completed"}
        end
      end)

    assert_receive {:worker, worker}
    assert {:error, _} = Operations.submit("duplicate", fn -> {:ok, "wrong"} end)
    send(worker, :finish)
    wait_for(id, "succeeded")
    assert Enum.find(Store.get()["operations"], &(&1["id"] == id))["result"] == "completed"
  end

  test "worker failure does not crash the command node" do
    {:ok, id} = Operations.submit("crashing", fn -> exit(:simulated_failure) end)
    wait_for(id, "failed")
    assert Process.alive?(Process.whereis(Operations))
  end

  defp wait_for(id, status, attempts \\ 100)
  defp wait_for(_, _, 0), do: flunk("operation did not reach terminal state")

  defp wait_for(id, status, attempts) do
    if Enum.find(Store.get()["operations"], &(&1["id"] == id))["status"] != status do
      Process.sleep(10)
      wait_for(id, status, attempts - 1)
    end
  end
end
