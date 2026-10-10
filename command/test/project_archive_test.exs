defmodule ElixirSSI.Command.ProjectArchiveTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.{ProjectArchive, Projects}

  setup do
    name = "archive_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf!(Path.join(Projects.root(), name))
      File.rm_rf!(Path.join(Projects.root(), name <> "_copy"))
    end)

    %{name: name}
  end

  test "export/import preserves source, binary resources and empty directories", %{name: name} do
    {:ok, _} = Projects.create(name)
    root = Path.join(Projects.root(), name)
    File.mkdir_p!(Path.join(root, "priv/empty"))
    File.write!(Path.join(root, "priv/image.bin"), <<0, 255, 1>>)
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "_build/ignored"), "not source")
    assert {:ok, archive} = ProjectArchive.export(name)
    assert {:ok, _} = ProjectArchive.import(name <> "_copy", archive)
    copy = Path.join(Projects.root(), name <> "_copy")
    assert File.read!(Path.join(copy, "priv/image.bin")) == <<0, 255, 1>>
    assert File.dir?(Path.join(copy, "priv/empty"))
    refute File.exists?(Path.join(copy, "_build"))
    assert {:error, _} = ProjectArchive.import(name, archive)
  end

  test "rejects traversal and ambiguous archives without creating a project", %{name: name} do
    for entries <- [
          [{~c"mix.exs", "mix"}, {~c"../escape", "bad"}],
          [{~c"mix.exs", "mix"}, {~c"MIX.EXS", "duplicate"}],
          [{~c"mix.exs", "mix"}, {~c"deps/untrusted", "bad"}],
          [{~c"README.md", "missing mix"}],
          [{~c"mix.exs", "mix"}, {~c"file", "one"}, {~c"file/child", "two"}]
        ] do
      {:ok, {_, archive}} = :zip.create(~c"test.zip", entries, [:memory])
      assert {:error, _} = ProjectArchive.import(name, archive)
      refute File.exists?(Path.join(Projects.root(), name))
    end
  end

  test "rejects invalid ZIP data", %{name: name} do
    assert {:error, _} = ProjectArchive.import(name, "not a zip")
  end
end
