defmodule ElixirSSI.CommandWeb.WorkspaceTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint ElixirSSI.CommandWeb.Endpoint

  test "workspace requires authentication on initial request and LiveView mount" do
    conn = build_conn() |> get("/")
    assert redirected_to(conn) == "/login"
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/")
  end

  test "authenticated settings survive the browser reconnect and reject invalid values" do
    conn =
      build_conn()
      |> init_test_session(%{"identity" => ElixirSSI.Command.Auth.session_identity()})

    {:ok, view, _} = live(conn, "/")
    view |> form("#instance-settings", nodes: "4", memory: "2048") |> render_submit()
    assert ElixirSSI.Command.Store.get()["nodes"] == 4
    assert render(view) =~ "Instance settings saved"

    assert render_submit(view, "configure", %{"nodes" => "65", "memory" => "2048"}) =~
             "Choose 1–64"

    assert ElixirSSI.Command.Store.get()["nodes"] == 4
    {:ok, reconnected, _} = live(conn, "/")
    assert has_element?(reconnected, "input[name=nodes][value='4']")

    saved =
      File.read!(Path.join(ElixirSSI.Command.Store.directory(), "configuration.json"))
      |> Jason.decode!()

    assert saved["nodes"] == 4
  end

  test "invalid login is refused and state-changing login requires CSRF" do
    conn = build_conn() |> get("/login")

    token =
      conn.resp_body
      |> Floki.parse_document!()
      |> Floki.find("input[name=_csrf_token]")
      |> Floki.attribute("value")
      |> hd()

    rejected =
      conn |> recycle() |> post("/login", %{"password" => "wrong", "_csrf_token" => token})

    assert rejected.status == 401
    assert get_session(rejected, :identity) == nil

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      build_conn()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/login", %{"password" => "test-command-password"})
    end
  end

  test "logout removes command authority" do
    conn =
      build_conn()
      |> init_test_session(%{"identity" => ElixirSSI.Command.Auth.session_identity()})
      |> get("/")

    token =
      conn.resp_body
      |> Floki.parse_document!()
      |> Floki.find("input[name=_csrf_token]")
      |> Floki.attribute("value")
      |> hd()

    logged_out = conn |> recycle() |> delete("/session", %{"_csrf_token" => token})
    assert get_session(logged_out, :identity) == nil
    assert redirected_to(logged_out) == "/login"
  end
end
