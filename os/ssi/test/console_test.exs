defmodule SSI.ConsoleTest do
  use ExUnit.Case, async: true
  alias SSI.Console.IOServer

  defp output(acc \\ "", until, timeout \\ 5_000) do
    receive do
      {:out, data} ->
        acc = acc <> data
        if String.contains?(acc, until), do: acc, else: output(acc, until, timeout)
    after
      timeout -> flunk("no #{inspect(until)} in output: #{inspect(acc)}")
    end
  end

  test "an IEx shell runs over the terminal I/O server" do
    test = self()
    {:ok, io} = IOServer.start_link(&send(test, {:out, &1}))

    spawn_link(fn ->
      Process.group_leader(self(), io)
      IEx.Server.run(dot_iex: "", register: false, prefix: "tty")
    end)

    assert output("1> ") =~ "1> "

    IOServer.feed(io, "40 + 2\n")
    assert output("2> ") =~ "42"

    # An expression split across lines is completed by the parser continuation.
    IOServer.feed(io, "Enum.sum([1,\n")
    IOServer.feed(io, "2, 3])\n")
    assert output("3> ") =~ "6"

    # Code the shell evaluates can read the terminal too; partial input waits.
    IOServer.feed(io, "IO.gets(\"name? \") |> String.upcase()\n")
    assert output("name? ") =~ "name? "
    IOServer.feed(io, "ada")
    IOServer.feed(io, "\n")
    assert output("4> ") =~ "ADA"
  end
end
