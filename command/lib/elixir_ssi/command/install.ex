defmodule ElixirSSI.Command.Install do
  @moduledoc "Upgrade an existing installation without discarding its identity or previous cards."

  def fresh!(assets, destination, platform) when platform in ["macos", "linux"] do
    if File.exists?(destination),
      do: raise("Installation already exists; refusing to replace its state")

    manifest = assets |> Path.join("installation.json") |> File.read!() |> Jason.decode!()

    roles = [
      "image",
      "emulator",
      "development",
      "source",
      "launcher",
      "command"
    ]

    paths =
      Map.new(roles, fn role ->
        record = Map.fetch!(manifest["assets"], role)
        name = record["name"]

        unless Path.basename(name) == name and name not in ["", ".", ".."],
          do: raise("Unsafe asset name")

        path = Path.join(assets, name)
        unless identity(path) == record["sha256"], do: raise("Checksum mismatch for #{name}")
        {role, path}
      end)

    for role <- ["emulator", "development"] do
      case ElixirSSI.Command.Runner.run("docker", ["load", "-i", paths[role]], timeout: 600_000) do
        {:ok, _} -> :ok
        {:error, error} -> raise(error)
      end
    end

    stage = destination <> ".installing-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    File.mkdir_p!(Path.join(stage, "image"))

    try do
      output = File.stream!(Path.join(stage, "image/elixirssi-cm5.img"), [:write, :binary])
      {_, 0} = System.cmd("gzip", ["-dc", paths["image"]], into: output)
      extract!(paths["source"], Path.join(stage, "source"))
      File.mkdir_p!(Path.join(stage, "state/command"))

      for name <- ["elixirssi", "ElixirSSI.command"] do
        File.cp!(paths["launcher"], Path.join(stage, name))
        File.chmod!(Path.join(stage, name), 0o755)
      end

      config =
        Map.put(
          manifest,
          "cluster_secret",
          Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        )

      File.write!(Path.join(stage, "installation.json"), Jason.encode!(config, pretty: true))
      File.chmod!(Path.join(stage, "installation.json"), 0o600)

      File.write!(
        Path.join(stage, "command-image"),
        Map.fetch!(manifest, "command_image") <> "\n"
      )

      if File.exists?(destination), do: raise("Installation destination appeared during setup")
      File.rename!(stage, destination)
      IO.puts("Installed ElixirSSI command node. Open ElixirSSI.command to enter the workspace.")
    after
      if File.exists?(stage), do: File.rm_rf!(stage)
    end
  end

  def extract!(archive, destination) do
    {:ok, entries} = :erl_tar.table(String.to_charlist(archive), [:compressed, :verbose])

    Enum.each(entries, fn {name, type, _, _, _, _, _} ->
      path = to_string(name)

      unless type in [:regular, :directory] and Path.type(path) == :relative and
               not Enum.any?(Path.split(path), &(&1 == "..")) and not String.contains?(path, "\\"),
             do: raise("Archive contains an unsafe path or link")
    end)

    File.mkdir_p!(destination)

    :ok =
      :erl_tar.extract(String.to_charlist(archive), [
        :compressed,
        {:cwd, String.to_charlist(destination)}
      ])
  end

  def adopt!(root, image_path, runtime_image, command_image, launcher) do
    manifest_path = Path.join(root, "installation.json")
    config = manifest_path |> File.read!() |> Jason.decode!()
    unless is_binary(config["cluster_secret"]), do: raise("Installation has no cluster identity")
    unless File.regular?(image_path), do: raise("New OS image is missing")
    unless File.regular?(launcher), do: raise("Workspace launcher is missing")

    unless String.starts_with?(runtime_image, "sha256:") and
             String.starts_with?(command_image, "sha256:"),
           do: raise("Installed container images must be pinned by identity")

    current = Path.join(root, "image/elixirssi-cm5.img")
    old_identity = identity(current)
    new_identity = identity(image_path)

    if old_identity != new_identity do
      File.cp!(image_path, current <> ".next")
      # Retain the original image so its persistent cards remain recoverable.
      previous = Path.join(root, "image/previous-#{old_identity}.img")
      unless File.exists?(previous), do: File.rename!(current, previous)
      File.rename!(current <> ".next", current)
    end

    backup = Path.join(root, "installation.before-command.json")
    unless File.exists?(backup), do: File.cp!(manifest_path, backup)
    config = config |> Map.put("image", runtime_image) |> Map.put("command_image", command_image)

    config =
      if old_identity != new_identity,
        do: Map.put(config, "previous_image_sha256", old_identity),
        else: config

    File.write!(manifest_path <> ".next", Jason.encode!(config, pretty: true))
    File.chmod!(manifest_path <> ".next", 0o600)
    File.rename!(manifest_path <> ".next", manifest_path)
    File.write!(Path.join(root, "command-image"), command_image <> "\n")

    for name <- ["elixirssi", "ElixirSSI.command"] do
      path = Path.join(root, name)

      if File.exists?(path) and not File.exists?(path <> ".previous"),
        do: File.cp!(path, path <> ".previous")

      File.cp!(launcher, path)
      File.chmod!(path, 0o755)
    end

    {:ok, %{previous_image: old_identity, image: new_identity, cluster_identity_preserved: true}}
  end

  defp identity(path) do
    File.stream!(path, 4 * 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
