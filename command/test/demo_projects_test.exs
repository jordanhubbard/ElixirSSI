defmodule ElixirSSI.Command.DemoProjectsTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.{DemoProjects, LocalFiles, Projects}

  defp snapshot do
    files = %{
      "lib/ssi/desktop/example_app.ex" => """
      defmodule SSI.Desktop.ExampleApp do
        @behaviour SSI.Desktop.App
        alias SSI.Desktop.App
        @impl true
        def short, do: "example"
        def title, do: App.title()
        def size, do: {300, 200}
      end
      """,
      "lib/ssi/desktop/app.ex" => """
      defmodule SSI.Desktop.App do
        @callback short() :: String.t()
        def title, do: "Example"
      end
      """
    }

    hashes = Map.new(files, fn {path, source} -> {path, LocalFiles.digest(source)} end)

    %{
      "id" => "example",
      "version" => "1.2.0",
      "node" => "test",
      "module" => "Elixir.SSI.Desktop.ExampleApp",
      "beam_md5" => "compiled-test-identity",
      "files" => files,
      "hashes" => hashes,
      "source_sha256" =>
        LocalFiles.digest(Jason.encode!(Enum.sort(hashes) |> Enum.map(&Tuple.to_list/1)))
    }
  end

  test "verified copy namespaces source, preserves originals and builds as a project" do
    name = "demo_#{System.unique_integer([:positive])}"
    root = Path.join(Projects.root(), name)
    on_exit(fn -> File.rm_rf!(root) end)
    snapshot = snapshot()
    assert {:ok, _} = DemoProjects.copy(snapshot, name)
    module = Macro.camelize(name)
    source = File.read!(root <> "/lib/example_app.ex")
    assert source =~ "defmodule #{module}.App"
    assert source =~ "alias #{module}.DesktopApp, as: App"

    assert File.read!(root <> "/priv/original/lib/ssi/desktop/example_app.ex") ==
             snapshot["files"]["lib/ssi/desktop/example_app.ex"]

    assert {:ok, metadata} = DemoProjects.metadata(name)
    assert metadata["original_module"] == snapshot["module"]
    assert metadata["module"] == "Elixir.#{module}.App"

    {output, code} =
      System.cmd("mix", ["test"], cd: root, stderr_to_stdout: true, env: [{"ERL_FLAGS", "+S 2"}])

    assert code == 0, output
    assert output =~ "1 passed"
    assert {:error, _} = DemoProjects.copy(snapshot, name)
  end

  test "rejects modified snapshot contents" do
    snapshot = snapshot()
    assert :ok = DemoProjects.verify(snapshot)
    tampered = put_in(snapshot, ["files", "lib/ssi/desktop/app.ex"], "changed")
    assert {:error, _} = DemoProjects.verify(tampered)
  end
end
