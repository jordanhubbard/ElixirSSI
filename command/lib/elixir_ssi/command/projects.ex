defmodule ElixirSSI.Command.Projects do
  @moduledoc "Project files belong to the workspace; builds run without command-node credentials."
  alias ElixirSSI.Command.{Store, Runner, Instances}
  @max_file 524_288
  def root, do: Path.join(Store.directory(), "projects")

  def deploy(project, target) do
    with {:ok, output} <- run(project, :bundle),
         {:ok, path} <- safe_path(project, ".ssi-deployment.json"),
         {:ok, %{type: :regular, size: size}} when size in 1..67_108_864 <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      upload = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      with {:ok, _} <- remote_call(target, "begin_upload", [upload, hash, size]),
           :ok <- transfer(target, upload, bytes),
           {:ok, result} <- remote_call(target, "finish_upload", [upload]) do
        {:ok, output <> "\nDeployed to #{target}:\n" <> result}
      else
        error ->
          remote_call(target, "cancel_upload", [upload])
          error
      end
    else
      {:error, error} -> {:error, inspect(error)}
      _ -> {:error, "Invalid or oversized deployment output."}
    end
  end

  defp remote_call(target, operation, arguments) do
    args =
      Enum.map_join(arguments, ", ", &inspect(&1, limit: :infinity, printable_limit: :infinity))

    source =
      "case SSI.Deploy.#{operation}(#{args}) do {:error, why} -> raise inspect(why); result -> result end"

    ElixirSSI.Command.Remote.evaluate(target, source)
  end

  defp transfer(_, _, <<>>), do: :ok

  defp transfer(target, upload, bytes) do
    # Base64 plus the SSH exec request must stay below OTP's packet limit.
    size = min(byte_size(bytes), 131_072)
    <<chunk::binary-size(^size), rest::binary>> = bytes

    case remote_call(target, "append_upload", [upload, Base.encode64(chunk)]) do
      {:ok, _} -> transfer(target, upload, rest)
      error -> error
    end
  end

  def list do
    File.mkdir_p!(root())
    File.ls!(root()) |> Enum.filter(&valid_name?/1) |> Enum.sort()
  end

  def create(name) do
    with true <- valid_name?(name),
         {:ok, path} <- safe_path(name, ""),
         :ok <- File.mkdir(path) do
      File.mkdir_p!(Path.join(path, "lib"))
      File.mkdir_p!(Path.join(path, "test"))
      module = Macro.camelize(name)

      File.write!(
        Path.join(path, "mix.exs"),
        "defmodule #{module}.MixProject do\n  use Mix.Project\n  def project, do: [app: :#{name}, version: \"0.1.0\", elixir: \"~> 1.20\", deps: []]\n  def application, do: [extra_applications: [:logger]]\nend\n"
      )

      File.write!(
        Path.join(path, "lib/#{name}.ex"),
        "defmodule #{module} do\n  @moduledoc \"An ElixirSSI application.\"\n  def hello, do: :world\nend\n"
      )

      File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")

      File.write!(
        Path.join(path, "test/#{name}_test.exs"),
        "defmodule #{module}Test do\n  use ExUnit.Case\n  test \"greets the cluster\" do\n    assert #{module}.hello() == :world\n  end\nend\n"
      )

      {:ok, "Created #{name}."}
    else
      false -> {:error, "Use a lowercase Elixir project name (letters, digits and underscores)."}
      {:error, :eexist} -> {:error, "That project already exists."}
      {:error, why} -> {:error, to_string(why)}
    end
  end

  def files(project) do
    with {:ok, path} <- safe_path(project, "") do
      {:ok, walk(path, "", 0)}
    end
  end

  def read(project, file) do
    with {:ok, path} <- safe_path(project, file),
         {:ok, %{type: :regular, size: size}} when size <= @max_file <- File.lstat(path),
         {:ok, text} <- File.read(path),
         true <- String.valid?(text),
         do: {:ok, text},
         else: (_ -> {:error, "Choose a UTF-8 source file smaller than 512 KiB."})
  end

  def save(project, file, text) do
    with true <- byte_size(text) <= @max_file and String.valid?(text),
         true <-
           Path.extname(file) in [".ex", ".exs", ".md", ".json", ".txt", ".heex", ".css", ".js"],
         {:ok, path} <- safe_path(project, file),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text) do
      {:ok, "Saved #{file}."}
    else
      _ ->
        {:error,
         "Cannot save this path or file type. Files must stay inside the project and be smaller than 512 KiB."}
    end
  end

  def run(project, action, source \\ "")
      when action in [:test, :format, :compile, :evaluate, :dependencies, :bundle] do
    with {:ok, _} <- safe_path(project, ""), {:ok, install} <- Instances.installation() do
      host_data = Application.get_env(:ssi_command, :data_host_dir) || Store.directory()
      project_host = Path.join([host_data, "projects", project])

      args =
        case action do
          :bundle ->
            script = File.read!(Application.app_dir(:ssi_command, "priv/export.exs"))
            ["mix", "run", "--no-start", "-e", script]

          :test ->
            ["mix", "test"]

          :format ->
            ["mix", "format", "mix.exs", "lib/**/*.ex", "test/**/*.exs"]

          :compile ->
            ["mix", "compile"]

          :dependencies ->
            [
              "elixir",
              "-e",
              "Enum.each([[\"local.hex\", \"--force\"], [\"deps.get\"]], fn args -> {_, status} = System.cmd(\"mix\", args, into: IO.stream(:stdio, :line)); if status != 0, do: System.halt(status) end)"
            ]

          :evaluate ->
            ["mix", "run", "--no-start", "-e", source]
        end

      # The job receives only its project, no Docker socket or command-node state.
      job = "ssi-work-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      result =
        Runner.run(
          "docker",
          [
            "run",
            "--rm",
            "--name",
            job,
            "--network",
            if(action == :dependencies, do: "bridge", else: "none"),
            "--memory",
            "1g",
            "--cpus",
            "2",
            "--pids-limit",
            "256",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--tmpfs",
            "/tmp:rw,nosuid,size=256m",
            "-e",
            "HOME=/tmp",
            "-e",
            "MIX_HOME=/work/.tools/mix",
            "-e",
            "HEX_HOME=/work/.tools/hex",
            "-e",
            "HEX_OFFLINE=#{if action == :dependencies, do: 0, else: 1}",
            "-v",
            project_host <> ":/work",
            "-w",
            "/work",
            install.config["builder"] | args
          ],
          timeout: 120_000
        )

      # Also remove a timed-out container; closing a Docker client does not stop it.
      Runner.run("docker", ["rm", "-f", job], timeout: 10_000)
      result
    end
  end

  def safe_path(project, relative) do
    File.mkdir_p!(root())
    pieces = Path.split(relative)

    if valid_name?(project) and Path.type(relative) == :relative and
         Enum.all?(pieces, &(&1 not in ["..", "."] and not String.contains?(&1, ["\\", "\0"]))) do
      parts = [project | if(relative == "", do: [], else: pieces)]

      result =
        Enum.reduce_while(parts, root(), fn part, parent ->
          path = Path.join(parent, part)

          case File.lstat(path) do
            {:ok, %{type: :symlink}} -> {:halt, :unsafe}
            {:ok, _} -> {:cont, path}
            {:error, :enoent} -> {:cont, path}
            _ -> {:halt, :unsafe}
          end
        end)

      if result == :unsafe, do: {:error, "Symlinks are not workspace paths."}, else: {:ok, result}
    else
      {:error, "Invalid workspace path."}
    end
  end

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,47}\z/, name)
  defp walk(_, _, depth) when depth > 8, do: []

  defp walk(root, relative, depth) do
    case File.ls(Path.join(root, relative)) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.take(500)
        |> Enum.flat_map(fn entry ->
          name = Path.join(relative, entry)

          case File.lstat(Path.join(root, name)) do
            {:ok, %{type: :directory}} when entry not in ["_build", "deps", ".git", ".tools"] ->
              walk(root, name, depth + 1)

            {:ok, %{type: :regular}} when entry != ".ssi-deployment.json" ->
              [name]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end
end
