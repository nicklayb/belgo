defmodule Belgo.Inventory.VirtualIp do
  @moduledoc """
  An address that is not a machine: a load balancer address (MetalLB, kube-vip), a
  floating address (keepalived)… Whichever machine answers for it, with its own MAC
  address, the address belongs to the `owner_id` device (a cluster, a host).

  `dns_names` resolve to the address (pushed as Unbound host overrides): a name
  without a dot is completed with the network domain. A virtual IP never gets a DHCP
  reservation nor a client name.
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.ListParams
  alias Belgo.Inventory.Types

  @kinds ~w(metallb kube_vip keepalived other)a
  @fields ~w(id name ip network_id kind owner_id dns_names notes)a
  @required ~w(id name ip kind)a

  embedded_schema do
    field(:name, :string)
    field(:ip, Types.IpAddress)
    field(:network_id, :string)
    field(:kind, Ecto.Enum, values: @kinds, default: :metallb)
    field(:owner_id, :string)
    field(:dns_names, {:array, :string}, default: [])
    field(:notes, :string)
  end

  @doc "Lists the kinds of virtual IPs."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Builds a changeset validating the virtual IP on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(virtual_ip, params) do
    params = ListParams.normalize(params, ["dns_names"])

    virtual_ip
    |> cast(params, @fields)
    |> Identifier.put_default(:name)
    |> validate_required(@required)
    |> Identifier.validate(:id)
    |> Identifier.validate(:network_id)
    |> Identifier.validate(:owner_id)
    |> update_change(:dns_names, fn names ->
      names
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
    end)
    |> validate_change(:dns_names, fn :dns_names, names ->
      case Enum.reject(names, &Interface.valid_dns_name?/1) do
        [] -> []
        invalid -> [dns_names: "invalid names: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end
end
