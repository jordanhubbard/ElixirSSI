defmodule ElixirSSI.Command.FolderSyncTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.{FolderSync, Projects, Store}

  setup do
    name = "sync_#{System.unique_integer([:positive])}"
    {:ok, _} = Projects.create(name)
    root = Path.join(Projects.root(), name)
    File.mkdir!(Path.join(root, "left"))
    File.mkdir!(Path.join(root, "right"))
    before = Store.get()["folder_sync"] || %{}

    on_exit(fn ->
      File.rm_rf!(root)
      Store.update(&Map.put(&1, "folder_sync", before))
    end)

    %{
      root: root,
      left: %{space: "project:" <> name, path: "left"},
      right: %{space: "project:" <> name, path: "right"}
    }
  end

  test "initial merge preserves unrelated files, binary bytes and empty folders", ctx do
    File.write!(ctx.root <> "/left/first", <<0, 255, 128>>)
    File.write!(ctx.root <> "/right/second", "other")
    File.mkdir!(ctx.root <> "/left/empty")
    assert {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    assert plan.conflicts == []
    assert length(plan.operations) == 3
    assert {:ok, _} = FolderSync.apply(plan)
    assert File.read!(ctx.root <> "/right/first") == <<0, 255, 128>>
    assert File.read!(ctx.root <> "/left/second") == "other"
    assert File.dir?(ctx.root <> "/right/empty")
    saved = File.read!(Path.join(Store.directory(), "configuration.json")) |> Jason.decode!()
    assert saved["folder_sync"][plan.id]["baseline"]["first"]["size"] == 3
    assert {:ok, next} = FolderSync.preview(ctx.left, ctx.right)
    assert next.operations == []
  end

  test "both-side edits require explicit conflict resolution", ctx do
    File.write!(ctx.root <> "/left/file", "base")
    {:ok, initial} = FolderSync.preview(ctx.left, ctx.right)
    {:ok, _} = FolderSync.apply(initial)
    File.write!(ctx.root <> "/left/file", "left change")
    File.write!(ctx.root <> "/right/file", "right change")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    assert [%{path: "file"}] = plan.conflicts
    assert {:error, _} = FolderSync.apply(plan)
    resolved = FolderSync.resolve(plan, %{"file" => "right"})
    assert resolved.conflicts == []
    assert {:ok, _} = FolderSync.apply(resolved)
    assert File.read!(ctx.root <> "/left/file") == "right change"
  end

  test "deletions use saved baseline and keep unrelated new files", ctx do
    File.mkdir_p!(ctx.root <> "/left/dir/empty")
    File.write!(ctx.root <> "/left/dir/file", "base")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    {:ok, _} = FolderSync.apply(plan)
    File.rm_rf!(ctx.root <> "/left/dir")
    File.write!(ctx.root <> "/right/new", "keep")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    assert plan.conflicts == []
    assert Enum.any?(plan.operations, &(&1.action == :delete and &1.path == "dir"))
    assert {:ok, _} = FolderSync.apply(plan)
    refute File.exists?(ctx.root <> "/right/dir")
    assert File.read!(ctx.root <> "/left/new") == "keep"
  end

  test "delete versus modified directory is one explicit subtree conflict", ctx do
    File.mkdir!(ctx.root <> "/left/dir")
    File.write!(ctx.root <> "/left/dir/file", "base")
    {:ok, initial} = FolderSync.preview(ctx.left, ctx.right)
    {:ok, _} = FolderSync.apply(initial)
    File.rm_rf!(ctx.root <> "/left/dir")
    File.write!(ctx.root <> "/right/dir/file", "edited")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    assert [%{path: "dir"}] = plan.conflicts
    assert {:ok, _} = plan |> FolderSync.resolve(%{"dir" => "right"}) |> FolderSync.apply()
    assert File.read!(ctx.root <> "/left/dir/file") == "edited"
  end

  test "directory versus file resolution replaces the whole reviewed subtree", ctx do
    File.mkdir!(ctx.root <> "/left/item")
    File.write!(ctx.root <> "/left/item/file", "child")
    File.write!(ctx.root <> "/right/item", "plain file")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    assert [%{path: "item"}] = plan.conflicts
    resolved = FolderSync.resolve(plan, %{"item" => "left"})
    assert {:ok, _} = FolderSync.apply(resolved)
    assert File.read!(ctx.root <> "/right/item/file") == "child"
  end

  test "stale tree and baseline previews cannot change files", ctx do
    File.write!(ctx.root <> "/left/file", "first")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    File.write!(ctx.root <> "/left/file", "changed")
    assert {:error, _} = FolderSync.apply(plan)
    refute File.exists?(ctx.root <> "/right/file")
    {:ok, current} = FolderSync.preview(ctx.left, ctx.right)
    assert {:ok, _} = FolderSync.apply(current)
    assert {:error, _} = FolderSync.apply(current)
  end

  test "excludes generated trees and rejects overlapping folders", ctx do
    File.mkdir!(ctx.root <> "/left/_build")
    File.write!(ctx.root <> "/left/_build/private", "generated")
    File.ln_s!(System.tmp_dir!(), ctx.root <> "/left/.git")
    {:ok, plan} = FolderSync.preview(ctx.left, ctx.right)
    assert plan.operations == []
    assert {:ok, _} = FolderSync.apply(plan)
    refute File.exists?(ctx.root <> "/right/_build")
    assert {:error, _} = FolderSync.preview(ctx.left, ctx.left)
    assert {:error, _} = FolderSync.preview(ctx.left, %{ctx.left | path: "left/inside"})
  end
end
