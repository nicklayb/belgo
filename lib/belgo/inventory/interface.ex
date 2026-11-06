defmodule Belgo.Inventory.Interface do
  @moduledoc """
  A network interface of a device: its MAC, address and where it is plugged.

  The `assignment` tells how the address is obtained:

    * `:reserved` – DHCP static mapping (needs a MAC and an IP)
    * `:static` – configured on the device itself (needs an IP)
    * `:dynamic` – plain DHCP lease, no address is managed

  `dns_names` are extra names resolving to the interface address (Unbound can have
  several names for one address). A name without a dot is completed with the network
  domain, a name with a dot is used as is.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.ListParams
  alias Belgo.Inventory.Types

  @type t :: %__MODULE__{}

  @assignments ~w(reserved static dynamic)a
  @fields ~w(name mac network_id ip assignment switch_id switch_port dns_names)a
  @dns_name_format ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:mac, Types.MacAddress)
    field(:network_id, :string)
    field(:ip, Types.IpAddress)
    field(:assignment, Ecto.Enum, values: @assignments, default: :reserved)
    field(:switch_id, :string)
    field(:switch_port, :string)
    field(:dns_names, {:array, :string}, default: [])
  end

  @doc "Lists the available address assignment modes."
  @spec assignments() :: [atom()]
  def assignments, do: @assignments

  @doc "Returns `true` for a DNS label or a fully qualified name (no wildcard)."
  @spec valid_dns_name?(String.t()) :: boolean()
  def valid_dns_name?(name), do: Regex.match?(@dns_name_format, name)

  @doc "Builds a changeset validating the interface on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(interface, params) do
    params = ListParams.normalize(params, ["dns_names"])

    interface
    |> cast(params, @fields)
    |> update_change(:dns_names, fn names ->
      names
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
    end)
    |> validate_dns_names()
    |> validate_required([:assignment])
    |> Identifier.validate(:network_id)
    |> Identifier.validate(:switch_id)
    |> validate_assignment()
    |> validate_switch_port()
  end

  defp validate_dns_names(changeset) do
    changeset
    |> validate_change(:dns_names, fn :dns_names, names ->
      case Enum.reject(names, &valid_dns_name?/1) do
        [] -> []
        invalid -> [dns_names: "invalid names: #{Enum.join(invalid, ", ")}"]
      end
    end)
    |> validate_names_need_address()
  end

  defp validate_names_need_address(changeset) do
    if get_field(changeset, :dns_names) != [] and is_nil(get_field(changeset, :ip)),
      do: add_error(changeset, :dns_names, "require an IP address"),
      else: changeset
  end

  defp validate_assignment(changeset) do
    case get_field(changeset, :assignment) do
      :reserved -> validate_required(changeset, [:mac, :ip])
      :static -> validate_required(changeset, [:ip])
      _dynamic -> changeset
    end
  end

  defp validate_switch_port(changeset) do
    if get_field(changeset, :switch_port) && is_nil(get_field(changeset, :switch_id)) do
      add_error(changeset, :switch_port, "requires a switch")
    else
      changeset
    end
  end
end
