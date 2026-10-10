defmodule ElixirSSI.Command.FileCopiesTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.{FileCopies, Projects}

  setup do
    name = "copy_#{System.unique_integer([:positive])}"
    {:ok, _} = Projects.create(name)
    root = Path.join(Projects.root(), name)
    File.write!(Path.join(root, "source.bin"), <<0, 128, 255>>)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, space: "project:" <> name}
  end

  test "reviewed copy preserves binary bytes", %{root: root, space: space} do
    assert {:ok, plan} = FileCopies.preview(space, "source.bin", space, "copy.bin")
    assert plan.destination_revision == :missing
    assert {:ok, _} = FileCopies.apply(plan)
    assert File.read!(Path.join(root, "copy.bin")) == <<0, 128, 255>>
    assert {:error, _} = FileCopies.preview(space, "source.bin", space, "source.bin")
  end

  test "rejects changed source and destination after preview", %{root: root, space: space} do
    assert {:ok, plan} = FileCopies.preview(space, "source.bin", space, "copy.bin")
    File.write!(Path.join(root, "copy.bin"), "external")
    assert {:error, _} = FileCopies.apply(plan)
    assert File.read!(Path.join(root, "copy.bin")) == "external"
    assert {:ok, plan} = FileCopies.preview(space, "source.bin", space, "other.bin")
    File.write!(Path.join(root, "source.bin"), "changed")
    assert {:error, _} = FileCopies.apply(plan)
    refute File.exists?(Path.join(root, "other.bin"))
  end
end
