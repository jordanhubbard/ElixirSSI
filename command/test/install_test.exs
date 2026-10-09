defmodule ElixirSSI.Command.InstallTest do
  use ExUnit.Case, async: true
  alias ElixirSSI.Command.Install

  setup do
    root = Path.join(System.tmp_dir!(), "ssi-install-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "archive extraction rejects traversal", %{root: root} do
    tar = Path.join(root, "unsafe.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(tar), [{~c"../escape", "not safe"}], [:compressed])
    assert_raise RuntimeError, ~r/unsafe/, fn -> Install.extract!(tar, Path.join(root, "out")) end
    refute File.exists?(Path.join(root, "escape"))
  end

  test "archive extraction accepts ordinary source files", %{root: root} do
    tar = Path.join(root, "source.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"lib/example.ex", "defmodule Example do end"}],
        [:compressed]
      )

    Install.extract!(tar, Path.join(root, "out"))
    assert File.read!(Path.join(root, "out/lib/example.ex")) == "defmodule Example do end"
  end

  test "archive extraction rejects external symlinks", %{root: root} do
    link = Path.join(root, "external")
    File.ln_s!("/etc/passwd", link)
    tar = Path.join(root, "linked.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"external", String.to_charlist(link)}], [
        :compressed
      ])

    assert_raise RuntimeError, ~r/unsafe/, fn -> Install.extract!(tar, Path.join(root, "out")) end
  end

  test "adoption preserves the secret, previous image, and project state", %{root: root} do
    installed = Path.join(root, "installed")
    File.mkdir_p!(Path.join(installed, "image"))
    File.mkdir_p!(Path.join(installed, "state/command/projects"))

    File.write!(
      Path.join(installed, "installation.json"),
      Jason.encode!(%{"cluster_secret" => "keep-me", "image" => "old"})
    )

    File.write!(Path.join(installed, "image/elixirssi-cm5.img"), "previous OS")
    File.write!(Path.join(installed, "state/command/projects/keep.ex"), "project data")
    File.write!(Path.join(root, "new.img"), "new OS")
    File.write!(Path.join(root, "launcher"), "#!/bin/sh\n")
    image = "sha256:" <> String.duplicate("a", 64)

    assert {:ok, result} =
             Install.adopt!(
               installed,
               Path.join(root, "new.img"),
               image,
               image,
               Path.join(root, "launcher")
             )

    assert File.read!(Path.join(installed, "image/previous-#{result.previous_image}.img")) ==
             "previous OS"

    assert File.read!(Path.join(installed, "state/command/projects/keep.ex")) == "project data"

    assert Jason.decode!(File.read!(Path.join(installed, "installation.json")))["cluster_secret"] ==
             "keep-me"

    assert File.read!(Path.join(installed, "image/elixirssi-cm5.img")) == "new OS"
  end
end
