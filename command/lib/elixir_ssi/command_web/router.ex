defmodule ElixirSSI.CommandWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ElixirSSI.CommandWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; connect-src 'self' ws: wss:; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'",
      "referrer-policy" => "no-referrer"
    }
  end

  scope "/", ElixirSSI.CommandWeb do
    pipe_through :browser
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/session/ticket", SessionController, :ticket
    delete "/session", SessionController, :delete
    get "/demos", FileController, :demos
    get "/files/download", FileController, :download
    get "/files/export", FileController, :export

    live_session :authenticated, on_mount: [{ElixirSSI.CommandWeb.Session, :require}] do
      live "/", WorkspaceLive
      live "/files", FilesLive
    end
  end
end
