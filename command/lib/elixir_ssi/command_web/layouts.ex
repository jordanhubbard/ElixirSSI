defmodule ElixirSSI.CommandWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>ElixirSSI · Command</title>
        <link rel="stylesheet" href="/app.css" />
        <script defer src="/assets/phoenix/phoenix.js">
        </script>
        <script defer src="/assets/live/phoenix_live_view.js">
        </script>
        <script defer src="/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def login(assigns) do
    ~H"""
    <main class="login">
      <div class="brand">λ ElixirSSI <span>COMMAND NODE</span></div>
      <h1>Your cluster.<br />Your Elixir workspace.</h1>
      <p>Sign in to develop and operate your single-system-image cluster.</p>
      <form method="post" action="/login">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <label for="password">Command-node password</label>
        <input id="password" type="password" name="password" required autocomplete="current-password" />
        <p :if={@error} role="alert">{@error}</p>
        <button>Open workspace</button>
      </form>
    </main>
    """
  end
end

defmodule ElixirSSI.CommandWeb.ErrorHTML do
  def render(template, _), do: Phoenix.Controller.status_message_from_template(template)
end
