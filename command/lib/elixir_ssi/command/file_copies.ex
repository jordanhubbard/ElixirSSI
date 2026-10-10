defmodule ElixirSSI.Command.FileCopies do
  @moduledoc "Reviewed copies across workspace locations with stale-input rejection."
  alias ElixirSSI.Command.{FileSpaces, LocalFiles}

  def preview(source_space, source_path, destination_space, destination_path) do
    with false <- source_space == destination_space and source_path == destination_path,
         {:ok, bytes} <- FileSpaces.call(source_space, :read, [source_path]),
         {:ok, destination_revision} <-
           FileSpaces.call(destination_space, :revision, [destination_path]) do
      {:ok,
       %{
         source_space: source_space,
         source_path: source_path,
         destination_space: destination_space,
         destination_path: destination_path,
         source_revision: LocalFiles.digest(bytes),
         destination_revision: destination_revision,
         size: byte_size(bytes)
       }}
    else
      true -> {:error, "Choose a different destination."}
      error -> error
    end
  end

  def apply(plan) do
    with {:ok, bytes} <- FileSpaces.call(plan.source_space, :read, [plan.source_path]),
         true <- LocalFiles.digest(bytes) == plan.source_revision,
         {:ok, _} <-
           FileSpaces.call(plan.destination_space, :write, [
             plan.destination_path,
             bytes,
             plan.destination_revision
           ]) do
      {:ok, "Copied #{plan.size} bytes to #{plan.destination_path}."}
    else
      false -> {:error, "Source changed. Preview the copy again."}
      error -> error
    end
  end
end
