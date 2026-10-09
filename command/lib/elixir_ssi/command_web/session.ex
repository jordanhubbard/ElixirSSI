defmodule ElixirSSI.CommandWeb.Session do
  import Phoenix.LiveView

  def on_mount(:require, _, session, socket) do
    if session["identity"] == ElixirSSI.Command.Auth.session_identity() do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end
end

defmodule ElixirSSI.CommandWeb.SessionController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def new(conn, _) do
    conn |> put_view(html: ElixirSSI.CommandWeb.Layouts) |> render(:login, error: nil)
  end

  def create(conn, %{"password" => password}) do
    if ElixirSSI.Command.Auth.valid?(password) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session(:identity, ElixirSSI.Command.Auth.session_identity())
      |> redirect(to: "/")
    else
      conn
      |> put_status(401)
      |> put_view(html: ElixirSSI.CommandWeb.Layouts)
      |> render(:login, error: "That password did not match this command node.")
    end
  end

  def create(conn, _), do: create(conn, %{"password" => ""})

  def ticket(conn, params) do
    if ElixirSSI.Command.Auth.consume_ticket(params["ticket"]) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session(:identity, ElixirSSI.Command.Auth.session_identity())
      |> send_resp(204, "")
    else
      conn
      |> put_status(401)
      |> text("This launch link expired or was already used. Open ElixirSSI again.")
    end
  end

  def delete(conn, _),
    do: conn |> clear_session() |> configure_session(drop: true) |> redirect(to: "/login")
end
