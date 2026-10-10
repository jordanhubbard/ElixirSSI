defmodule SSI.Desktop.App do
  @moduledoc """
  Contract for desktop applications.

  An application's state lives in the desktop process. `render/3` returns
  RemoteOS drawing operations for its window body `{x, y, w, h}`;
  `message/3` receives whatever the application's own background work sends
  as `{:app, ctx.id, msg}` to `ctx.desktop`. Optional callbacks hook ticks,
  input, pixel uploads and surface resets after a reconnect.
  """

  @callback short() :: String.t()
  @callback title() :: String.t()
  @callback size() :: {pos_integer, pos_integer}
  @callback init(ctx :: map) :: term
  @callback render(state :: term, ctx :: map, {integer, integer, integer, integer}) :: list
  @callback message(term, state :: term, ctx :: map) :: term
  @callback tick(state :: term, ctx :: map) :: term | {:dirty, term}
  @callback event(map, state :: term, ctx :: map) :: term
  @callback uploads(state :: term, ctx :: map) :: [{integer, binary}]
  @doc "The desktop has accepted pending pixels into its upload queue."
  @callback uploaded(state :: term) :: term
  @doc "Mark pixels for resend after reconnecting to new, empty surfaces."
  @callback reset_surfaces(state :: term) :: term
  @callback close(state :: term) :: any
  @doc "Optional per-window square pixel surfaces; each window receives its own handles in ctx.tiles."
  @callback tile_count() :: pos_integer
  @callback tile_size() :: pos_integer
  @doc "Small term saved with the desktop checkpoint; survives failover."
  @callback checkpoint(state :: term) :: term
  @doc "Re-create state from `checkpoint/1` output on another node."
  @callback restore(saved :: term, ctx :: map) :: term
  @optional_callbacks tick: 2, event: 3, uploads: 2, uploaded: 1, reset_surfaces: 1, close: 1, checkpoint: 1, restore: 2, tile_count: 0, tile_size: 0

  @palette [0x61AFEF, 0xE5C07B, 0x98C379, 0xE06C75, 0xC678DD, 0x56B6C2, 0xD19A66, 0xF0A0C0, 0xA0E0A0, 0xB0B0FF]

  @doc "Stable display colour of a member: its rank in the sorted membership."
  def node_color(node) do
    case Enum.find_index(SSI.Cluster.members(), &(&1 == node)) do
      nil -> 0x808080
      i -> Enum.at(@palette, rem(i, length(@palette)))
    end
  end

  def truncate(text, chars) do
    text = to_string(text)
    if String.length(text) > chars, do: String.slice(text, 0, max(chars - 1, 0)) <> "~", else: text
  end
end
