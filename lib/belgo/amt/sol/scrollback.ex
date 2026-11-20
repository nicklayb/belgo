defmodule Belgo.Amt.Sol.Scrollback do
  @moduledoc """
  The last bytes of a console (pure), replayed when a page attaches to a running
  session. `offset` counts every byte ever received, so a page can skip the output
  messages already contained in the replay.
  """

  @default_capacity_bytes 64 * 1024

  defstruct content: "", offset: 0, capacity: @default_capacity_bytes

  @type t :: %__MODULE__{
          content: binary(),
          offset: non_neg_integer(),
          capacity: pos_integer()
        }

  @doc "An empty scrollback keeping at most `capacity` bytes."
  @spec new(pos_integer()) :: t()
  def new(capacity \\ @default_capacity_bytes), do: %__MODULE__{capacity: capacity}

  @doc "Appends received bytes, dropping the oldest ones beyond the capacity."
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = scrollback, data) do
    content = scrollback.content <> data
    overflow = max(byte_size(content) - scrollback.capacity, 0)

    %{
      scrollback
      | content: binary_part(content, overflow, byte_size(content) - overflow),
        offset: scrollback.offset + byte_size(data)
    }
  end
end
