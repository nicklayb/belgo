defmodule Belgo.Inventory.Device do
  @moduledoc """
  Any machine or peripheral of the homelab, physical or virtual.

  A device is placed in exactly one way (see `placement/1`):

    * in a location (`location_id`)
    * on a host (`host_id`), e.g. a VM on a Proxmox node or a container on a Docker host
    * portable, meaning it has no fixed location
    * unplaced, when nothing is known yet

  Devices running virtualisation software list it in `platforms`. Network devices
  (`kind: network`) can have a `network_role` (gateway, switch, access point) placing
  them in the routing; a device is plugged where its interfaces' `switch_id` says, or,
  for network devices without interface (unmanaged switches), where `uplink_id` /
  `uplink_port` say. Switches can declare their number of ports (`port_count`) and
  whether they supply Power over Ethernet (`poe`); other devices never keep them.
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.ListParams
  alias Belgo.Inventory.SortParams
  alias Belgo.Inventory.MetadataEntry

  @kinds ~w(server workstation laptop phone tablet media gaming iot network printer appliance other)a
  @platforms ~w(proxmox docker kubernetes)a
  @virtualizations ~w(virtual_machine lxc container)a
  @placements ~w(location host portable unplaced)a
  @network_roles ~w(gateway switch access_point)a
  @fields ~w(id name hostname kind network_role port_count poe uplink_id uplink_port location_id host_id virtualization portable platforms tags notes)a
  @required ~w(id name kind)a
  @list_fields ~w(platforms tags)
  @sort_params ~w(interfaces_sort metadata_sort)
  @hostname_format ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/

  @type placement ::
          {:location, String.t()} | {:host, String.t()} | :portable | :unplaced

  embedded_schema do
    field(:name, :string)
    field(:hostname, :string)
    field(:kind, Ecto.Enum, values: @kinds, default: :other)
    field(:network_role, Ecto.Enum, values: @network_roles)
    field(:port_count, :integer)
    field(:poe, :boolean, default: false)
    field(:uplink_id, :string)
    field(:uplink_port, :string)
    field(:location_id, :string)
    field(:host_id, :string)
    field(:virtualization, Ecto.Enum, values: @virtualizations)
    field(:portable, :boolean, default: false)
    field(:platforms, {:array, Ecto.Enum}, values: @platforms, default: [])
    field(:tags, {:array, :string}, default: [])
    field(:notes, :string)
    field(:placement, Ecto.Enum, values: @placements, virtual: true)

    embeds_many(:interfaces, Interface, on_replace: :delete)
    embeds_many(:metadata, MetadataEntry, on_replace: :delete)
  end

  @doc "Lists the available device kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Lists the virtualisation platforms a device can run."
  @spec platforms() :: [atom()]
  def platforms, do: @platforms

  @doc "Lists how a guest can run on its host."
  @spec virtualizations() :: [atom()]
  def virtualizations, do: @virtualizations

  @doc "Lists the roles of network devices in the routing (gateway, switch, AP)."
  @spec network_roles() :: [atom()]
  def network_roles, do: @network_roles

  @doc "Returns `true` for gateways, switches and access points."
  @spec network_node?(t()) :: boolean()
  def network_node?(%__MODULE__{network_role: role}), do: role != nil

  @doc "Returns `true` for switches."
  @spec switch?(t()) :: boolean()
  def switch?(%__MODULE__{network_role: role}), do: role == :switch

  @doc "Returns `true` for switches supplying Power over Ethernet."
  @spec poe?(t()) :: boolean()
  def poe?(%__MODULE__{} = device), do: switch?(device) and device.poe

  @doc "Lists the placement modes."
  @spec placements() :: [atom()]
  def placements, do: @placements

  @doc """
  Builds a changeset validating the device on its own.

  When a `placement` param is given (forms), fields irrelevant to that placement are
  cleared. Otherwise (files), the placement fields must not contradict each other.
  The virtual `placement` field is never kept in the resulting record.
  List fields accept comma separated strings.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(device, params) do
    params =
      params
      |> ListParams.normalize(@list_fields)
      |> SortParams.new_last(@sort_params)

    device
    |> cast(params, @fields ++ [:placement])
    |> cast_embed(:interfaces,
      with: &Interface.changeset/2,
      sort_param: :interfaces_sort,
      drop_param: :interfaces_drop
    )
    |> cast_embed(:metadata,
      with: &MetadataEntry.changeset/2,
      sort_param: :metadata_sort,
      drop_param: :metadata_drop
    )
    |> validate_unique_metadata_labels()
    |> Identifier.put_default(:name)
    |> validate_required(@required)
    |> Identifier.validate(:id)
    |> Identifier.validate(:location_id)
    |> Identifier.validate(:host_id)
    |> Identifier.validate(:uplink_id)
    |> validate_uplink()
    |> update_change(:hostname, &String.downcase/1)
    |> validate_format(:hostname, @hostname_format, message: "must be a valid DNS label")
    |> put_network_kind()
    |> validate_switch()
    |> validate_placement()
  end

  @doc "Returns how the device is placed."
  @spec placement(t()) :: placement()
  def placement(%__MODULE__{host_id: host_id}) when is_binary(host_id), do: {:host, host_id}

  def placement(%__MODULE__{location_id: location_id}) when is_binary(location_id),
    do: {:location, location_id}

  def placement(%__MODULE__{portable: true}), do: :portable
  def placement(%__MODULE__{}), do: :unplaced

  @doc "Returns the placement mode (`:location`, `:host`, `:portable` or `:unplaced`)."
  @spec placement_mode(t()) :: atom()
  def placement_mode(%__MODULE__{} = device) do
    case placement(device) do
      {mode, _id} -> mode
      mode -> mode
    end
  end

  @doc "Returns the DNS hostname of the device, defaulting to its identifier."
  @spec hostname(t()) :: String.t()
  def hostname(%__MODULE__{hostname: hostname}) when is_binary(hostname), do: hostname
  def hostname(%__MODULE__{id: id}), do: id

  @doc """
  Human label of one of the device interfaces, used as description on the network
  services: `Skynet (enp4s0)`, or `Skynet` when the interface has no name.
  """
  @spec interface_label(t(), Interface.t()) :: String.t()
  def interface_label(%__MODULE__{name: name}, %Interface{name: interface_name})
      when is_binary(interface_name) and interface_name != "",
      do: "#{name} (#{interface_name})"

  def interface_label(%__MODULE__{name: name}, %Interface{}), do: name

  @doc "Returns `true` when the device runs at least one virtualisation platform."
  @spec host?(t()) :: boolean()
  def host?(%__MODULE__{platforms: platforms}), do: platforms != []

  @doc "Returns the DNS names attached to the device's addresses."
  @spec dns_names(t()) :: [String.t()]
  def dns_names(%__MODULE__{interfaces: interfaces}),
    do: Enum.flat_map(interfaces, & &1.dns_names)

  @doc "Returns the IP addresses of the device's interfaces."
  @spec ip_addresses(t()) :: [String.t()]
  def ip_addresses(%__MODULE__{interfaces: interfaces}) do
    interfaces
    |> Enum.map(& &1.ip)
    |> Enum.reject(&is_nil/1)
  end

  defp validate_unique_metadata_labels(changeset) do
    duplicates =
      changeset
      |> get_field(:metadata)
      |> Enum.map(&String.downcase(&1.label || ""))
      |> Enum.frequencies()
      |> Enum.filter(fn {label, count} -> label != "" and count > 1 end)

    if duplicates == [],
      do: changeset,
      else: add_error(changeset, :metadata, "each label can only be used once")
  end

  defp validate_uplink(changeset) do
    cond do
      get_field(changeset, :uplink_port) && is_nil(get_field(changeset, :uplink_id)) ->
        add_error(changeset, :uplink_port, "requires the device it is plugged into")

      get_field(changeset, :uplink_id) &&
          get_field(changeset, :uplink_id) == get_field(changeset, :id) ->
        add_error(changeset, :uplink_id, "cannot be the device itself")

      true ->
        changeset
    end
  end

  defp validate_switch(changeset) do
    if get_field(changeset, :network_role) == :switch,
      do: validate_number(changeset, :port_count, greater_than: 0),
      else: change(changeset, port_count: nil, poe: false)
  end

  defp put_network_kind(changeset) do
    if get_field(changeset, :network_role),
      do: put_change(changeset, :kind, :network),
      else: changeset
  end

  defp validate_placement(changeset) do
    changeset =
      case get_change(changeset, :placement) do
        nil -> validate_exclusive_placement(changeset)
        placement -> apply_placement(changeset, placement)
      end

    delete_change(changeset, :placement)
  end

  defp apply_placement(changeset, :location) do
    changeset
    |> change(host_id: nil, virtualization: nil, portable: false)
    |> validate_required([:location_id])
  end

  defp apply_placement(changeset, :host) do
    changeset
    |> change(location_id: nil, portable: false)
    |> validate_required([:host_id, :virtualization])
    |> validate_not_own_host()
  end

  defp apply_placement(changeset, :portable) do
    change(changeset, location_id: nil, host_id: nil, virtualization: nil, portable: true)
  end

  defp apply_placement(changeset, :unplaced) do
    change(changeset, location_id: nil, host_id: nil, virtualization: nil, portable: false)
  end

  defp validate_exclusive_placement(changeset) do
    placements =
      Enum.filter(
        [
          location_id: get_field(changeset, :location_id) != nil,
          host_id: get_field(changeset, :host_id) != nil,
          portable: get_field(changeset, :portable)
        ],
        fn {_field, set?} -> set? end
      )

    case placements do
      [_first, _second | _rest] ->
        add_error(changeset, :placement, "only one of location, host or portable can be set")

      [host_id: true] ->
        changeset
        |> validate_required([:virtualization])
        |> validate_not_own_host()

      _single_or_none ->
        changeset
    end
  end

  defp validate_not_own_host(changeset) do
    if get_field(changeset, :host_id) == get_field(changeset, :id) do
      add_error(changeset, :host_id, "cannot be the device itself")
    else
      changeset
    end
  end
end
