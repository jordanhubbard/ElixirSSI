defmodule ElixirSSI.CommandWeb.FileController do
  use Phoenix.Controller, formats: [:html]

  def demos(conn, params),
    do:
      redirect(conn,
        to:
          "/?" <>
            URI.encode_query(Map.put(Map.take(params, ["target", "id"]), "project", "Demos"))
      )

  alias ElixirSSI.Command.{Auth, FileSpaces, ProjectArchive}
  plug :authenticated

  defp authenticated(conn, _) do
    if get_session(conn, :identity) == Auth.session_identity(),
      do: conn,
      else: conn |> send_resp(401, "Sign in to access files.") |> halt()
  end

  def download(conn, %{"space" => space, "path" => path}) do
    case FileSpaces.call(space, :read, [path]) do
      {:ok, bytes} ->
        send_download(conn, {:binary, bytes},
          filename: Path.basename(path),
          content_type: "application/octet-stream"
        )

      error ->
        conn |> put_status(400) |> text(FileSpaces.message(error))
    end
  end

  def download(conn, _), do: conn |> put_status(400) |> text("Choose a file.")

  def export(conn, %{"project" => name}) do
    case ProjectArchive.export(name) do
      {:ok, bytes} ->
        send_download(conn, {:binary, bytes},
          filename: name <> ".zip",
          content_type: "application/zip"
        )

      error ->
        conn |> put_status(400) |> text(FileSpaces.message(error))
    end
  end

  def export(conn, _), do: conn |> put_status(400) |> text("Choose a project.")
end
