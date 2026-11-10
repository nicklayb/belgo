defmodule BelgoWeb.Format do
  @moduledoc "Human readable labels for inventory values."

  use Gettext, backend: BelgoWeb.Gettext

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Location

  @device_icons %{
    server: "hero-server",
    workstation: "hero-computer-desktop",
    laptop: "hero-computer-desktop",
    phone: "hero-device-phone-mobile",
    tablet: "hero-device-tablet",
    media: "hero-tv",
    gaming: "hero-puzzle-piece",
    iot: "hero-cpu-chip",
    network: "hero-wifi",
    printer: "hero-printer",
    camera: "hero-video-camera",
    appliance: "hero-cube",
    other: "hero-question-mark-circle"
  }
  @guest_icons %{
    virtual_machine: "hero-square-3-stack-3d",
    lxc: "hero-cube-transparent",
    container: "hero-cube"
  }
  @location_icons %{
    site: "hero-home-modern",
    building: "hero-building-office",
    floor: "hero-bars-3-bottom-left",
    room: "hero-map-pin",
    rack: "hero-server-stack",
    other: "hero-map-pin"
  }
  @values_domain "values"
  @acronyms %{
    iot: "IoT",
    lxc: "LXC",
    opnsense: "OPNsense",
    adguard: "AdGuard Home",
    omada: "Omada",
    home_assistant: "Home Assistant",
    access_point: "Access point",
    metallb: "MetalLB",
    kube_vip: "kube-vip",
    keepalived: "keepalived"
  }

  @doc """
  Turns an atom such as `:virtual_machine` into `Virtual machine`, translated through
  the `values` gettext domain (`priv/gettext/*/LC_MESSAGES/values.po`, maintained by
  hand since the labels are built at runtime).
  """
  @spec label(atom() | nil) :: String.t()
  def label(nil), do: ""

  def label(value) when is_atom(value) do
    english =
      case Map.fetch(@acronyms, value) do
        {:ok, acronym} ->
          acronym

        :error ->
          value
          |> Atom.to_string()
          |> String.replace("_", " ")
          |> String.capitalize()
      end

    Gettext.dgettext(BelgoWeb.Gettext, @values_domain, english)
  end

  @doc "Builds `{label, value}` select options from atoms."
  @spec options([atom()]) :: [{String.t(), atom()}]
  def options(values), do: Enum.map(values, &{label(&1), &1})

  @doc "Icon class of a device: guests are drawn by how they run, others by kind."
  @spec device_icon(Device.t()) :: String.t()
  def device_icon(%Device{host_id: host_id, virtualization: virtualization})
      when is_binary(host_id) and is_map_key(@guest_icons, virtualization),
      do: Map.fetch!(@guest_icons, virtualization)

  def device_icon(%Device{kind: kind}), do: Map.get(@device_icons, kind, @device_icons.other)

  @doc "Icon of a device kind."
  @spec kind_icon(atom()) :: String.t()
  def kind_icon(kind), do: Map.get(@device_icons, kind, @device_icons.other)

  @role_icons %{
    gateway: "hero-globe-alt",
    switch: "hero-arrows-right-left",
    access_point: "hero-wifi"
  }

  @doc "Icon class of a network role."
  @spec role_icon(atom()) :: String.t()
  def role_icon(role), do: Map.get(@role_icons, role, "hero-server")

  @doc "Icon class of a location kind."
  @spec location_icon(Location.t()) :: String.t()
  def location_icon(%Location{kind: kind}),
    do: Map.get(@location_icons, kind, @location_icons.other)

  @doc "Label of an address assignment mode."
  @spec assignment(atom()) :: String.t()
  def assignment(:reserved), do: gettext("DHCP reservation")
  def assignment(:static), do: gettext("Static")
  def assignment(:dynamic), do: gettext("DHCP")

  @doc "Label of an observation source."
  @spec source(atom()) :: String.t()
  def source(:kea_subnet), do: gettext("Kea subnet")
  def source(:kea_reservation), do: gettext("Kea reservation")
  def source(:unbound_host_override), do: gettext("Unbound override")
  def source(:adguard_rewrite), do: gettext("DNS rewrite")
  def source(:adguard_client), do: gettext("Persistent client")
  def source(:adguard_auto_client), do: gettext("Auto client")
  def source(:opnsense_gateway), do: gettext("Gateway")
  def source(:omada_device), do: gettext("Network device")
  def source(:omada_client), do: gettext("Client")
  def source(:home_assistant_floor), do: gettext("Floor")
  def source(:home_assistant_area), do: gettext("Area")
  def source(source), do: label(source)

  @doc "Short, locale neutral timestamp."
  @spec datetime(DateTime.t() | nil) :: String.t()
  def datetime(nil), do: "—"
  def datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  @doc "Flash friendly description of records preventing a deletion."
  @spec references([{atom(), String.t(), String.t()}]) :: String.t()
  def references(references) do
    names = Enum.map_join(references, ", ", fn {_collection, _id, name} -> name end)
    gettext("Still used by: %{names}", names: names)
  end
end
