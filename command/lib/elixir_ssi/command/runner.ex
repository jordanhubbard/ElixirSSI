defmodule ElixirSSI.Command.Runner do
  @moduledoc "Bounded external tools. Arguments never pass through a shell."
  def run(executable, args, opts \\ []) do
    case System.find_executable(executable) do
      nil ->
        {:error, "Required tool #{executable} is unavailable on this command node."}

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [:binary, :exit_status, :stderr_to_stdout, args: args] ++
              Keyword.take(opts, [:cd, :env])
          )

        deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 60_000)
        collect(port, deadline, "")
    end
  end

  defp collect(port, deadline, output) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} ->
        combined = output <> bytes

        limited =
          if byte_size(combined) > 262_144,
            do: binary_part(combined, byte_size(combined) - 262_144, 262_144),
            else: combined

        collect(port, deadline, limited)

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, code}} ->
        {:error, "Exit #{code}: #{output}"}
    after
      remaining ->
        Port.close(port)
        {:error, "Operation timed out. Check actual node state before retrying."}
    end
  end
end
