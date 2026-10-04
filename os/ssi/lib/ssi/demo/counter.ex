defmodule SSI.Demo.Counter do
  @moduledoc """
  The smallest useful cluster service, and a template for writing one.

      SSI.Service.register(:counter, SSI.Demo.Counter)
      SSI.Demo.Counter.inc()            # from any node
      migrate(:counter, "ssi-550003")   # move it; the count moves with it

  State is checkpointed on every change, so it also survives the abrupt loss
  of the machine running it.
  """
  use GenServer

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def inc(name \\ :counter), do: SSI.Service.call(name, :inc)
  def value(name \\ :counter), do: SSI.Service.call(name, :value)

  @impl true
  def init(%{ssi_service: name}) do
    Process.flag(:trap_exit, true)
    {:ok, %{name: name, n: SSI.Service.restore(name) || 0}}
  end

  @impl true
  def handle_call(:inc, _from, s) do
    n = s.n + 1
    SSI.Service.checkpoint(s.name, n)
    {:reply, n, %{s | n: n}}
  end

  def handle_call(:value, _from, s), do: {:reply, s.n, s}
  def handle_call(:where, _from, s), do: {:reply, node(), s}

  @impl true
  def terminate(_reason, s), do: SSI.Service.checkpoint(s.name, s.n)
end
