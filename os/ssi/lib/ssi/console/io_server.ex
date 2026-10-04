defmodule SSI.Console.IOServer do
  @moduledoc """
  An Erlang I/O server for a line-oriented terminal.

  IEx (and every `IO` call made by code it evaluates) talks to its group
  leader with the Erlang I/O protocol. This server implements that protocol
  over two plain functions — `write` sends bytes to the terminal, and `feed/2`
  delivers bytes typed on it — so a shell can run on any terminal the system
  can open (`SSI.Console.TTY` wires it to a virtual console). Line editing and
  echo are left to the kernel's line discipline.
  """
  use GenServer

  def start_link(write) when is_function(write, 1), do: GenServer.start_link(__MODULE__, write)

  @doc "Deliver input received from the terminal."
  def feed(server, data), do: send(server, {:input, data})

  @impl true
  def init(write), do: {:ok, %{write: write, buf: "", waiting: nil, eof: false}}

  @impl true
  def handle_info({:input, data}, state), do: {:noreply, serve(%{state | buf: state.buf <> data})}
  def handle_info(:eof, state), do: {:noreply, serve(%{state | eof: true})}

  def handle_info({:io_request, from, ref, req}, state) do
    case request(req, state) do
      {:reply, reply, state} ->
        send(from, {:io_reply, ref, reply})
        {:noreply, state}

      {:wait, pending, state} ->
        {:noreply, serve(%{state | waiting: {from, ref, pending}})}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # -- requests ---------------------------------------------------------------

  defp request({:put_chars, _enc, chars}, state), do: put(chars, state)
  defp request({:put_chars, chars}, state), do: put(chars, state)
  defp request({:put_chars, _enc, m, f, a}, state), do: put(apply(m, f, a), state)
  defp request({:put_chars, m, f, a}, state), do: put(apply(m, f, a), state)

  defp request({:get_line, _enc, prompt}, state), do: get({:line}, prompt, state)
  defp request({:get_line, prompt}, state), do: get({:line}, prompt, state)
  defp request({:get_chars, _enc, prompt, _n}, state), do: get({:line}, prompt, state)
  defp request({:get_chars, prompt, _n}, state), do: get({:line}, prompt, state)
  defp request({:get_until, _enc, prompt, m, f, a}, state), do: get({:until, m, f, a, []}, prompt, state)
  defp request({:get_until, prompt, m, f, a}, state), do: get({:until, m, f, a, []}, prompt, state)

  defp request({:get_geometry, _}, state), do: {:reply, {:error, :enotsup}, state}
  defp request(:getopts, state), do: {:reply, [binary: true, encoding: :unicode], state}
  defp request({:setopts, _}, state), do: {:reply, :ok, state}

  defp request({:requests, reqs}, state) do
    Enum.reduce_while(reqs, {:reply, :ok, state}, fn req, {:reply, _, st} ->
      case request(req, st) do
        {:reply, {:error, _} = e, st} -> {:halt, {:reply, e, st}}
        {:reply, r, st} -> {:cont, {:reply, r, st}}
        wait -> {:halt, wait}
      end
    end)
  end

  defp request(_, state), do: {:reply, {:error, :request}, state}

  defp put(chars, state) do
    state.write.(IO.chardata_to_string(chars))
    {:reply, :ok, state}
  end

  defp get(pending, prompt, state) do
    case prompt do
      p when p in [~c"", "", nil] -> :ok
      p -> state.write.(IO.chardata_to_string(p))
    end

    {:wait, pending, state}
  end

  # Answer the waiting reader with complete lines from the buffer.
  defp serve(%{waiting: nil} = state), do: state

  defp serve(%{waiting: {from, ref, pending}} = state) do
    case take_line(state) do
      :none ->
        state

      {line, state} ->
        case advance(pending, line) do
          {:done, reply, rest} ->
            send(from, {:io_reply, ref, reply})
            serve(%{state | waiting: nil, buf: rest <> state.buf})

          {:more, pending} ->
            serve(%{state | waiting: {from, ref, pending}})
        end
    end
  end

  defp take_line(%{buf: buf} = state) do
    case :binary.split(buf, "\n") do
      [line, rest] -> {line <> "\n", %{state | buf: rest}}
      [_] when state.eof -> {:eof, state}
      [_] -> :none
    end
  end

  defp advance({:line}, :eof), do: {:done, :eof, ""}
  defp advance({:line}, line), do: {:done, line, ""}

  defp advance({:until, m, f, a, cont}, line) do
    chars = if line == :eof, do: :eof, else: String.to_charlist(line)

    case apply(m, f, [cont, chars | a]) do
      {:done, result, rest} -> {:done, result, rest_to_binary(rest)}
      {:more, cont} -> {:more, {:until, m, f, a, cont}}
    end
  end

  defp rest_to_binary(:eof), do: ""
  defp rest_to_binary(rest), do: IO.chardata_to_string(rest)
end
