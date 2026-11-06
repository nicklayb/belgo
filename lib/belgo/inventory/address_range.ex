defmodule Belgo.Inventory.AddressRange do
  @moduledoc """
  A logical range of a network: a name for consecutive addresses (`.1`–`.5` routing,
  `.10`–`.20` physical servers…), purely descriptive. With a device `kind`, devices of
  that kind get the first free address of the range suggested for their interfaces
  (`Belgo.Inventory.AddressAllocation`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Types
  alias Belgo.Network.IpAddress

  @type t :: %__MODULE__{}

  @fields ~w(name start end kind)a
  @required ~w(name start end)a

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:start, Types.IpAddress)
    field(:end, Types.IpAddress)
    field(:kind, Ecto.Enum, values: Device.kinds())
  end

  @doc "Builds a changeset validating the range on its own (bounds in order)."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(range, params) do
    range
    |> cast(params, @fields)
    |> validate_required(@required)
    |> validate_order()
  end

  @doc "Returns `true` when the address (string) is within the range."
  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{start: first, end: last}, address) do
    case IpAddress.parse(address) do
      {:ok, _parsed} ->
        IpAddress.sort_key(first) <= IpAddress.sort_key(address) and
          IpAddress.sort_key(address) <= IpAddress.sort_key(last)

      :error ->
        false
    end
  end

  @doc "Returns `true` when two ranges share at least one address."
  @spec overlap?(t(), t()) :: boolean()
  def overlap?(%__MODULE__{} = left_range, %__MODULE__{} = right_range) do
    IpAddress.sort_key(left_range.start) <= IpAddress.sort_key(right_range.end) and
      IpAddress.sort_key(right_range.start) <= IpAddress.sort_key(left_range.end)
  end

  defp validate_order(changeset) do
    first = get_field(changeset, :start)
    last = get_field(changeset, :end)

    if first && last && IpAddress.sort_key(first) > IpAddress.sort_key(last),
      do: add_error(changeset, :end, "must come after the start of the range"),
      else: changeset
  end
end
