defmodule SSI.Status.BootRecord do
  @moduledoc """
  How this member's previous boot ended.

  Because the BEAM is PID 1, a member that fails does not linger half-alive:
  its death panics the kernel and the board reboots. So the useful question
  after a member comes back is how its last boot ended, and the member is the
  only witness. At boot it reads `boot.json` from its data partition, then
  writes a fresh record for this boot; `alive/0` refreshes the record while
  the member runs, and `ended/1` marks an orderly restart or power-off just
  before reboot(2). A record that was never marked ended means the boot ended
  without warning: power loss, a kernel panic or a BEAM failure.

  The previous boot is reported as `%{"ended" => "clean", "action" => ...}`,
  `%{"ended" => "unclean", "alive_at" => ms}` or `%{"ended" => "unknown"}`
  (first boot, or no persistent data partition).
  """

  @file_name "boot.json"
  @key {__MODULE__, :boot}

  @doc "Read the previous record and start this boot's. Called once, at boot."
  def start(dir \\ SSI.Boot.data_dir(), persistent \\ SSI.Boot.persistent?()) do
    now = System.os_time(:millisecond)
    id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    previous = if persistent, do: classify(read(dir)), else: %{"ended" => "unknown"}
    :persistent_term.put(@key, %{id: id, dir: dir, booted_at: now, previous: previous})
    write(dir, %{"boot_id" => id, "booted_at" => now, "alive_at" => now, "ended" => nil})
    previous
  end

  @doc "This boot's id: unique per boot of a member."
  def boot_id, do: current()[:id] || "hosted"

  @doc "How the previous boot ended."
  def previous, do: current()[:previous] || %{"ended" => "unknown"}

  @doc "Note that this boot is still alive (called every 30 seconds)."
  def alive, do: update(&Map.put(&1, "alive_at", System.os_time(:millisecond)))

  @doc "Mark this boot as ended cleanly by `action` (`:restart` or `:poweroff`)."
  def ended(action) do
    now = System.os_time(:millisecond)
    update(&Map.merge(&1, %{"alive_at" => now, "ended" => to_string(action), "ended_at" => now}))
  end

  @doc false
  def classify(nil), do: %{"ended" => "unknown"}

  def classify(%{"ended" => nil} = r),
    do: %{"ended" => "unclean", "booted_at" => r["booted_at"], "alive_at" => r["alive_at"]}

  def classify(%{"ended" => action} = r),
    do: %{"ended" => "clean", "action" => action, "booted_at" => r["booted_at"], "at" => r["ended_at"]}

  def classify(_), do: %{"ended" => "unknown"}

  defp current, do: :persistent_term.get(@key, %{})

  defp update(fun) do
    case current() do
      %{dir: dir, id: id} ->
        case read(dir) do
          %{"boot_id" => ^id} = record -> write(dir, fun.(record))
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp read(dir) do
    with {:ok, text} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{} = record} <- JSON.decode(text) do
      record
    else
      _ -> nil
    end
  end

  # Write-then-rename, so a power cut leaves the old record or the new one.
  defp write(dir, record) do
    path = Path.join(dir, @file_name)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, JSON.encode!(record), [:sync]) do
      File.rename(tmp, path)
    end
  end
end
