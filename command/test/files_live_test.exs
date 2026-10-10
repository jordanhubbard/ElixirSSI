defmodule ElixirSSI.CommandWeb.FilesLiveTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ElixirSSI.Command.{Auth, Projects, LocalFiles, Store}
  @endpoint ElixirSSI.CommandWeb.Endpoint

  setup do
    project = "files_#{System.unique_integer([:positive])}"
    {:ok, _} = Projects.create(project)
    root = Path.join(Projects.root(), project)
    on_exit(fn -> File.rm_rf!(root) end)
    conn = build_conn() |> init_test_session(%{"identity" => Auth.session_identity()})

    %{
      conn: conn,
      project: project,
      root: root,
      url: "/files?space=project:" <> project <> "&right=project:" <> project
    }
  end

  test "files, downloads and archives require authentication", %{project: project} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/files")

    assert get(build_conn(), "/files/download", %{space: "project:" <> project, path: "mix.exs"}).status ==
             401

    assert get(build_conn(), "/files/export", %{project: project}).status == 401
  end

  test "creates and edits files, rejects stale saves, renames and deletes", %{
    conn: conn,
    root: root,
    url: url
  } do
    {:ok, view, _} = live(conn, url)
    render_click(view, "tool", %{"name" => "create"})
    view |> form("#create-entry", name: "note.txt", kind: "file") |> render_submit()
    render_click(view, "open-file", %{"path" => "note.txt"})
    send(view.pid, :cluster_changed)
    assert has_element?(view, "#file-editor")
    view |> form("#file-editor", source: "saved from browser") |> render_submit()
    assert File.read!(Path.join(root, "note.txt")) == "saved from browser"
    File.write!(Path.join(root, "note.txt"), "external edit")

    assert view |> form("#file-editor", source: "stale") |> render_submit() =~
             "Destination changed"

    assert File.read!(Path.join(root, "note.txt")) == "external edit"

    assert render_submit(view, "rename", %{"from" => "note.txt", "to" => "renamed.txt"}) =~
             "renamed.txt"

    assert :ok = File.write(Path.join(root, "renamed.txt"), "delete me")
    render_click(view, "open-file", %{"path" => "renamed.txt"})
    view |> element("button[phx-click=delete][phx-value-path='renamed.txt']") |> render_click()
    refute File.exists?(Path.join(root, "renamed.txt"))
  end

  test "binary upload and download preserve bytes", %{
    conn: conn,
    root: root,
    url: url,
    project: project
  } do
    {:ok, view, _} = live(conn, url)
    bytes = <<0, 255, 1, 128>>

    render_click(view, "tool", %{"name" => "upload"})

    upload =
      file_input(view, "#upload-files", :files, [
        %{name: "image.bin", content: bytes, type: "application/octet-stream"}
      ])

    assert render_upload(upload, "image.bin") =~ "100%"
    view |> form("#upload-files") |> render_submit()
    assert File.read!(Path.join(root, "image.bin")) == bytes
    response = get(conn, "/files/download", %{space: "project:" <> project, path: "image.bin"})
    assert response.status == 200
    assert response.resp_body == bytes
    assert get_resp_header(response, "content-disposition") |> hd() =~ "attachment"
  end

  test "download rejects escape paths and exported project includes saved source", %{
    conn: conn,
    project: project
  } do
    assert get(conn, "/files/download", %{
             space: "project:" <> project,
             path: "../configuration.json"
           }).status == 400

    archive = get(conn, "/files/export", %{project: project})
    assert archive.status == 200
    {:ok, entries} = :zip.extract(archive.resp_body, [:memory])
    assert Enum.any?(entries, fn {name, _} -> name == ~c"mix.exs" end)
  end

  test "imports a project ZIP through the browser", %{conn: conn, project: project, url: url} do
    copy = project <> "_imported"
    on_exit(fn -> File.rm_rf!(Path.join(Projects.root(), copy)) end)

    {:ok, {_, zip}} =
      :zip.create(
        ~c"project.zip",
        [{~c"mix.exs", "# imported source"}, {~c"priv/banner.txt", "resource"}],
        [:memory]
      )

    {:ok, view, _} = live(conn, url)

    render_click(view, "tool", %{"name" => "projects"})

    upload =
      file_input(view, "#import-project", :project, [
        %{name: "project.zip", content: zip, type: "application/zip"}
      ])

    render_upload(upload, "project.zip")
    view |> form("#import-project", name: copy) |> render_submit()
    assert File.read!(Path.join([Projects.root(), copy, "priv/banner.txt"])) == "resource"
    assert has_element?(view, "option[selected][value='project:#{copy}']")
  end

  test "copy preview names overwrite and requires a separate apply", %{
    conn: conn,
    project: project,
    root: root,
    url: url
  } do
    File.write!(Path.join(root, "source.txt"), "source")
    File.write!(Path.join(root, "destination.txt"), "old")
    {:ok, view, _} = live(conn, url)
    render_click(view, "open-file", %{"path" => "source.txt"})

    render_submit(view, "preview-copy", %{
      "space" => "project:" <> project,
      "path" => "destination.txt"
    })

    assert render_async(view) =~ "Replaces the existing destination"
    assert File.read!(Path.join(root, "destination.txt")) == "old"
    view |> element("button[phx-click=apply-copy]") |> render_click()
    assert render_async(view) =~ "Copied 6 bytes"
    assert File.read!(Path.join(root, "destination.txt")) == "source"
  end

  test "independent panes copy in both directions and refresh the destination", %{
    conn: conn,
    project: project,
    root: root
  } do
    File.mkdir!(root <> "/left")
    File.mkdir!(root <> "/right")
    File.write!(root <> "/left/file.txt", "local")

    url =
      "/files?" <>
        URI.encode_query(%{
          left: "project:" <> project,
          left_path: "left",
          right: "project:" <> project,
          right_path: "right"
        })

    {:ok, view, _} = live(conn, url)
    refute has_element?(view, "#file-editor")
    refute has_element?(view, "#create-entry")
    assert has_element?(view, "#copy-right[disabled]")
    view |> element("#pane-left button[phx-click=pane-select]") |> render_click()
    view |> element("#copy-right") |> render_click()
    assert render_async(view) =~ "Creates a new file"
    view |> element("button[phx-click=apply-copy]") |> render_click()
    render_async(view)
    assert File.read!(root <> "/right/file.txt") == "local"
    assert has_element?(view, "#pane-right button[phx-value-path='right/file.txt']")
    assert has_element?(view, "#location-left input[name=path][value=left]")
    assert has_element?(view, "#location-right input[name=path][value=right]")
    File.write!(root <> "/right/file.txt", "remote")
    view |> element("#pane-right button[phx-click=pane-select]") |> render_click()
    view |> element("#copy-left") |> render_click()
    assert render_async(view) =~ "Replaces the existing destination"
    File.write!(root <> "/left/file.txt", "concurrent change")
    view |> element("button[phx-click=apply-copy]") |> render_click()
    assert render_async(view) =~ "Destination changed"
    assert File.read!(root <> "/left/file.txt") == "concurrent change"
    view |> element("#copy-left") |> render_click()
    render_async(view)
    view |> element("button[phx-click=apply-copy]") |> render_click()
    render_async(view)
    assert File.read!(root <> "/left/file.txt") == "remote"

    view
    |> form("#location-left", side: "left", space: "project:" <> project, path: "")
    |> render_submit()

    assert has_element?(view, "#location-right input[name=path][value=right]")
    assert has_element?(view, "#pane-right button[aria-pressed=true]")
  end

  test "unlinking an open folder returns to an available location", %{
    conn: conn,
    project: project
  } do
    previous = Store.get()["linked_folders"] || []

    Store.update(
      &Map.put(&1, "linked_folders", [
        %{
          "id" => "removed",
          "name" => "Temporary link",
          "host_path" => "/unavailable",
          "writable" => false
        }
      ])
    )

    on_exit(fn -> Store.update(&Map.put(&1, "linked_folders", previous)) end)
    {:ok, view, _} = live(conn, "/files?left=link:removed&right=project:" <> project)
    render_async(view)
    render_click(view, "unlink-folder", %{"id" => "removed"})
    render_async(view)
    refute has_element?(view, "option[value='link:removed']")
    assert has_element?(view, "#pane-left button[phx-value-path='mix.exs']")
    refute has_element?(view, "#pane-left .pane-error")
  end

  test "Demos is a project and legacy links open that project", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?section=projects")
    assert has_element?(view, "button[phx-value-project=Demos]")
    refute has_element?(view, "a[href='/demos']")
    view |> element("button[phx-value-project=Demos]") |> render_click()
    assert has_element?(view, "#demos-project")

    assert redirected_to(get(conn, "/demos", %{id: "mandelbrot"})) ==
             "/?id=mandelbrot&project=Demos"
  end

  test "delete cannot silently remove a concurrently changed file", %{
    conn: conn,
    root: root,
    url: url
  } do
    {:ok, first} = LocalFiles.write(root, "note.txt", "first")
    {:ok, view, _} = live(conn, url)
    File.write!(Path.join(root, "note.txt"), "changed")

    assert render_click(view, "delete", %{"path" => "note.txt", "revision" => first}) =~
             "File changed"

    assert File.read!(Path.join(root, "note.txt")) == "changed"
  end
end
