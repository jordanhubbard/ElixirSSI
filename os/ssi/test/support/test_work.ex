defmodule SSI.TestWork do
  @moduledoc false
  # Code that tests run on peer nodes must be compiled onto the shared code path.

  def square_where(i), do: {i * i, node()}

  def slow(i) do
    Process.sleep(100)
    i
  end
end

defmodule SSI.TestWork.Counter do
  @moduledoc false
  use GenServer
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(%{ssi_service: name}) do
    Process.flag(:trap_exit, true)
    {:ok, {name, SSI.Service.restore(name) || 0}}
  end

  @impl true
  def handle_call(:inc, _from, {name, n}), do: {:reply, n + 1, {name, n + 1}}

  @impl true
  def terminate(_reason, {name, n}), do: SSI.Service.checkpoint(name, n)
end
