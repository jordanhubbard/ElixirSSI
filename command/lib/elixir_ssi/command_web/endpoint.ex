defmodule ElixirSSI.CommandWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ssi_command

  @session [
    store: :cookie,
    key: "_ssi_command",
    signing_salt: "ssi-session",
    same_site: "Strict",
    http_only: true,
    max_age: 86400
  ]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]
  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/assets/live", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Static, at: "/", from: :ssi_command, only: ~w(app.css app.js)
  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded], pass: [], length: 1_048_576
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session
  plug ElixirSSI.CommandWeb.Router
end
