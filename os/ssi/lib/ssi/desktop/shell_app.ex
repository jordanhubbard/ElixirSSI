defmodule SSI.Desktop.ShellApp do
  @moduledoc """
  An Elixir shell in a window, with the system shell commands imported.

  Input is evaluated in a dedicated evaluator process that keeps bindings
  between lines; output written by the evaluated code is captured and shown.
  """
  @behaviour SSI.Desktop.App
  alias SSI.Remote

  @cols 72
  @rows 26
  @max_lines 300
  @key_return 13
  @key_backspace 8
  @key_escape 27
  @key_up 1_073_741_906
  @key_down 1_073_741_905

  @impl true
  def short, do: "shell"
  @impl true
  def title, do: "Shell"
  @impl true
  def size, do: {@cols * 8 + 16, @rows * 10 + 12}

  @impl true
  def init(ctx) do
    %{desktop: desktop, id: id} = ctx
    evaluator = spawn_link(fn -> evaluator(desktop, id) end)
    banner = SSI.Shell.motd() |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    lines = add([], banner <> "\nTry: nodes, top, mandel, run(fn -> node() end), ls \"/\"")
    %{lines: lines, input: "", evaluator: evaluator, busy: false, history: [], hpos: -1}
  end

  @impl true
  def checkpoint(state), do: %{lines: Enum.take(state.lines, -100), history: Enum.take(state.history, 50)}

  @impl true
  def restore(saved, ctx) do
    state = init(ctx)
    note = "--- desktop restarted on #{SSI.Boot.hostname()}; bindings were not carried over ---"
    %{state | lines: add(saved.lines, note), history: saved.history}
  end

  @impl true
  def close(state), do: Process.exit(state.evaluator, :kill)

  @impl true
  def message({:output, text}, state, _ctx) do
    %{state | lines: add(state.lines, text), busy: false}
  end

  def message(_, state, _), do: state

  @impl true
  def event(%{"kind" => 1, "code" => @key_return}, %{busy: false} = state, _ctx) do
    line = state.input
    send(state.evaluator, {:eval, line})
    history = if line == "", do: state.history, else: [line | state.history]
    %{state | lines: add(state.lines, prompt() <> line), input: "", busy: line != "", history: history, hpos: -1}
  end

  def event(%{"kind" => 1, "code" => @key_backspace}, state, _ctx),
    do: %{state | input: String.slice(state.input, 0, max(String.length(state.input) - 1, 0))}

  def event(%{"kind" => 1, "code" => @key_escape}, state, _ctx), do: %{state | input: ""}
  def event(%{"kind" => 1, "code" => @key_up}, state, _ctx), do: recall(state, state.hpos + 1)
  def event(%{"kind" => 1, "code" => @key_down}, state, _ctx), do: recall(state, state.hpos - 1)

  def event(%{"kind" => 1, "text" => text}, state, _ctx) when is_binary(text) and text != "",
    do: %{state | input: state.input <> text}

  def event(_, state, _), do: state

  defp recall(state, pos) do
    cond do
      pos < 0 -> %{state | input: "", hpos: -1}
      pos >= length(state.history) -> state
      true -> %{state | input: Enum.at(state.history, pos), hpos: pos}
    end
  end

  defp prompt, do: SSI.Boot.hostname() <> "> "

  defp add(lines, text) do
    new =
      text
      |> String.split("\n")
      |> Enum.flat_map(fn l -> if l == "", do: [""], else: l |> String.graphemes() |> Enum.chunk_every(@cols) |> Enum.map(&Enum.join/1) end)

    Enum.take(lines ++ new, -@max_lines)
  end

  @impl true
  def render(state, ctx, {x, y, _w, _h}) do
    fb = ctx.fb
    cursor = if rem(div(System.monotonic_time(:millisecond), 500), 2) == 0, do: "_", else: " "
    input = if state.busy, do: "(running...)", else: prompt() <> state.input <> cursor
    visible = Enum.take(state.lines ++ add([], input), -@rows)

    [
      Remote.fill(fb, x, y, @cols * 8 + 14, @rows * 10 + 10, 0x0C0E14),
      visible
      |> Enum.with_index()
      |> Enum.map(fn {line, i} -> Remote.text(fb, x + 6, y + 6 + i * 10, line, 0xD6E2D0) end)
    ]
  end

  @impl true
  def tick(state, _ctx) do
    phase = rem(div(System.monotonic_time(:millisecond), 500), 2)
    if phase != Map.get(state, :phase), do: {:dirty, Map.put(state, :phase, phase)}, else: state
  end

  # -- evaluator --------------------------------------------------------------

  defp evaluator(desktop, id) do
    env = Code.env_for_eval([])
    {_, binding, env} = Code.eval_quoted_with_env(quote(do: import(SSI.Shell)), [], env)
    eval_loop(desktop, id, binding, env)
  end

  defp eval_loop(desktop, id, binding, env) do
    receive do
      {:eval, ""} ->
        eval_loop(desktop, id, binding, env)

      {:eval, code} ->
        {:ok, io} = StringIO.open("")
        previous = Process.group_leader()
        Process.group_leader(self(), io)

        {result, binding, env} =
          try do
            {value, binding, env} = Code.eval_quoted_with_env(Code.string_to_quoted!(code), binding, env)
            {value, binding, env}
          rescue
            e -> {{:error_text, Exception.format(:error, e, __STACKTRACE__) |> String.split("\n") |> Enum.take(3) |> Enum.join("\n")}, binding, env}
          catch
            kind, reason -> {{:error_text, Exception.format(kind, reason) |> String.split("\n") |> hd()}, binding, env}
          end

        Process.group_leader(self(), previous)
        {_, output} = StringIO.contents(io)
        StringIO.close(io)

        shown =
          case result do
            {:error_text, text} -> text
            :"do not show this result in output" -> nil
            value -> inspect(value, pretty: true, width: @cols, limit: 50)
          end

        send(desktop, {:app, id, {:output, String.trim_trailing(output <> (shown || ""))}})
        eval_loop(desktop, id, binding, env)
    end
  end
end
