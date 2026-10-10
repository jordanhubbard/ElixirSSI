defmodule ElixirSSI.CommandWeb.FolderSyncLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ElixirSSI.Command.{Auth, Projects, Store}
  @endpoint ElixirSSI.CommandWeb.Endpoint

  test "browser previews a conflict, resolves it, applies and retains the baseline" do
    name = "sync_ui_#{System.unique_integer([:positive])}"
    {:ok, _} = Projects.create(name)
    root = Path.join(Projects.root(), name)
    File.mkdir!(root <> "/left")
    File.mkdir!(root <> "/right")
    File.write!(root <> "/left/file", "left")
    File.write!(root <> "/right/file", "right")
    baseline = Store.get()["folder_sync"] || %{}

    on_exit(fn ->
      File.rm_rf!(root)
      Store.update(&Map.put(&1, "folder_sync", baseline))
    end)

    conn = build_conn() |> init_test_session(%{"identity" => Auth.session_identity()})

    url =
      "/files?" <>
        URI.encode_query(%{
          left: "project:" <> name,
          left_path: "left",
          right: "project:" <> name,
          right_path: "right"
        })

    {:ok, view, _} = live(conn, url)
    render_click(view, "tool", %{"name" => "sync"})
    send(view.pid, :changed)
    assert has_element?(view, "#location-right option[value='project:#{name}'][selected]")
    assert has_element?(view, "#location-right input[name=path][value=right]")
    view |> element("#preview-sync") |> render_click()
    assert render_async(view, 5_000) =~ "Resolve conflicts"
    assert has_element?(view, "button[phx-click=apply-sync][disabled]")
    view |> form("#resolve-sync", choice_0: "left") |> render_submit()
    refute has_element?(view, "#resolve-sync")
    assert render(view) =~ "Replace file"
    assert File.read!(root <> "/right/file") == "right"
    view |> element("button[phx-click=apply-sync]") |> render_click()
    wait_for(fn -> render(view) =~ "Both folders agree" end)
    assert File.read!(root <> "/right/file") == "left"
    assert has_element?(view, "#location-right option[value='project:#{name}'][selected]")
    assert has_element?(view, "#location-right input[name=path][value=right]")
    view |> element("#preview-sync") |> render_click()
    render_async(view, 5_000)
    File.write!(root <> "/left/file", "changed after preview")
    view |> element("button[phx-click=apply-sync]") |> render_click()
    wait_for(fn -> render(view) =~ "Folders or synchronization baseline changed" end)
    assert has_element?(view, "#location-right option[value='project:#{name}'][selected]")
    assert has_element?(view, "#location-right input[name=path][value=right]")
    {:ok, reconnected, _} = live(conn, url)
    render_click(reconnected, "tool", %{"name" => "sync"})
    assert has_element?(reconnected, "button[phx-click=preview-saved-sync]")
    assert render(reconnected) =~ "succeeded"
  end

  defp wait_for(fun, remaining \\ 100)
  defp wait_for(fun, 0), do: assert(fun.())

  defp wait_for(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_for(fun, remaining - 1)
        )
  end
end
