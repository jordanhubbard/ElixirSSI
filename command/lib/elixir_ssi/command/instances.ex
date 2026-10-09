defmodule ElixirSSI.Command.Instances do
  @moduledoc "Own the installed emulated cluster while retaining its existing identity and cards."
  alias ElixirSSI.Command.{Runner, Store}

  def installation do
    root = Application.get_env(:ssi_command, :installation_dir)
    host = Application.get_env(:ssi_command, :installation_host_dir) || root

    with true <- is_binary(root) and is_binary(host),
         {:ok, bytes} <- File.read(Path.join(root, "installation.json")),
         {:ok, config} <- Jason.decode(bytes),
         true <- is_binary(config["image"]) and is_binary(config["cluster_secret"]) do
      key = :crypto.hash(:sha256, host) |> Base.encode16(case: :lower) |> binary_part(0, 12)
      {:ok, %{root: root, host: host, config: config, name: "elixirssi-" <> key}}
    else
      _ ->
        {:error,
         "Connect an ElixirSSI installation to this command node before starting instances."}
    end
  end

  def status do
    with {:ok, install} <- installation(),
         {:ok, text} <-
           Runner.run(
             "docker",
             ["ps", "-a", "--filter", "name=^/" <> install.name <> "$", "--format", "{{json .}}"],
             timeout: 10_000
           ) do
      case String.trim(text) do
        "" ->
          {:ok,
           %{"state" => "stopped", "detail" => "Instances are stopped; their cards are retained."}}

        data ->
          case Jason.decode(data) do
            {:ok, value} -> {:ok, %{"state" => value["State"], "detail" => value["Status"]}}
            _ -> {:error, "Docker returned an unreadable status."}
          end
      end
    end
  end

  def start do
    with {:ok, install} <- installation(),
         {:ok, %{"state" => state}} when state in ["stopped", "exited", "created", "dead"] <-
           status() do
      if state != "stopped", do: Runner.run("docker", ["rm", install.name])
      config = Store.get()
      count = config["nodes"]

      ports =
        for i <- 1..count,
            base <- [8180, 8480, 2320],
            arg <- ["-p", "127.0.0.1:#{base + i}:#{base + i}"],
            do: arg

      # Pass secrets through the inherited environment rather than command arguments.
      extra = "ssi.ssh.password=elixir ssi.secret=" <> install.config["cluster_secret"]

      args =
        [
          "run",
          "-d",
          "--init",
          "--name",
          install.name,
          "--platform",
          "linux/arm64",
          "-e",
          "SSI_NODES=#{count}",
          "-e",
          "SSI_CM5_MEM=#{config["memory"]}",
          "-e",
          "SSI_CM5_APPEND",
          "-e",
          "SSI_PREVIOUS_IMAGE=#{install.config["previous_image_sha256"] || ""}",
          "-v",
          install.host <> "/image:/os/build/cm5:ro",
          "-v",
          install.name <> "-cards:/os/build/cm5emu"
        ] ++ ports ++ [install.config["image"]]

      case Runner.run("docker", args, env: [{~c"SSI_CM5_APPEND", String.to_charlist(extra)}]) do
        {:ok, _} ->
          await_ready(install, count, System.monotonic_time(:millisecond) + 240_000)

        {:error, message} ->
          {:error, String.replace(message, install.config["cluster_secret"], "[redacted]")}
      end
    else
      {:ok, _} ->
        {:error, "Instances are already running. Stop them before changing their configuration."}

      error ->
        error
    end
  end

  defp await_ready(install, count, deadline) do
    case status() do
      {:ok, %{"state" => "running"}} ->
        host = Application.get_env(:ssi_command, :guest_host, "127.0.0.1")

        ready =
          Enum.all?(1..count, fn index ->
            case ElixirSSI.Command.Cluster.fetch("http://#{host}:#{8180 + index}") do
              {:ok, %{"system" => %{"members" => ^count}}} -> true
              _ -> false
            end
          end)

        cond do
          ready ->
            {:ok, "#{count} instances are online and agree on cluster membership."}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             "The container is running, but the cluster did not become ready within four minutes. Inspect node logs before retrying."}

          true ->
            Process.sleep(2000)
            await_ready(install, count, deadline)
        end

      _ ->
        output =
          case logs() do
            {:ok, value} -> value
            {:error, value} -> value
          end

        {:error,
         "Instances stopped during startup:\n" <>
           String.replace(output, install.config["cluster_secret"], "[redacted]")}
    end
  end

  def stop do
    with {:ok, install} <- installation(),
         {:ok, _} <- Runner.run("docker", ["stop", "-t", "30", install.name], timeout: 45_000),
         do: {:ok, "Instances stopped. Persistent cards are retained."}
  end

  def restart do
    with {:ok, _} <- stop(), do: start()
  end

  def logs do
    with {:ok, install} <- installation(),
         do: Runner.run("docker", ["logs", "--tail", "100", install.name], timeout: 10_000)
  end
end
