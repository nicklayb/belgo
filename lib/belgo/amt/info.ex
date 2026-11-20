defmodule Belgo.Amt.Info do
  @moduledoc """
  What AMT tells about its machine (read with the user's credentials, kept in the
  page only): power state, AMT firmware, chassis, BIOS, processors and memory. Built
  (pure) from the pulled instances of each class (`build/1`). Field names follow
  the DMTF / Intel schemas; **not yet verified against real hardware**.
  """

  alias Belgo.Amt.Power
  alias Belgo.Amt.Vulnerability

  @classes [
    "CIM_SoftwareIdentity",
    "CIM_Chassis",
    "CIM_BIOSElement",
    "CIM_Chip",
    "CIM_PhysicalMemory"
  ]
  @power_class "CIM_AssociatedPowerManagementService"
  @firmware_instance "AMT"
  @build_instance "Build Number"
  @processor_marker "Processor"

  defstruct power_state: :unknown,
            firmware_version: nil,
            firmware_build: nil,
            manufacturer: nil,
            model: nil,
            serial_number: nil,
            bios_vendor: nil,
            bios_version: nil,
            bios_release_date: nil,
            processors: [],
            memory_bytes: nil

  @type items :: [%{String.t() => String.t()}]
  @type t :: %__MODULE__{
          power_state: Power.state(),
          firmware_version: String.t() | nil,
          firmware_build: String.t() | nil,
          manufacturer: String.t() | nil,
          model: String.t() | nil,
          serial_number: String.t() | nil,
          bios_vendor: String.t() | nil,
          bios_version: String.t() | nil,
          bios_release_date: String.t() | nil,
          processors: [String.t()],
          memory_bytes: non_neg_integer() | nil
        }

  @doc "The class holding the power state (read first: it decides whether the account works)."
  @spec power_class() :: String.t()
  def power_class, do: @power_class

  @doc "The other classes read for the information card."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @doc "The power state of the pulled `CIM_AssociatedPowerManagementService` instances."
  @spec power_state(items()) :: Power.state()
  def power_state(items) do
    items
    |> Enum.find_value(&Map.get(&1, "PowerState"))
    |> Power.state()
  end

  @doc "Builds the information from the pulled instances, keyed by class."
  @spec build(%{String.t() => items()}) :: t()
  def build(items_by_class) do
    identities = Map.get(items_by_class, "CIM_SoftwareIdentity", [])
    chassis = first(items_by_class, "CIM_Chassis")
    bios = first(items_by_class, "CIM_BIOSElement")

    %__MODULE__{
      power_state: power_state(Map.get(items_by_class, @power_class, [])),
      firmware_version: version_of(identities, @firmware_instance),
      firmware_build: version_of(identities, @build_instance),
      manufacturer: present(chassis["Manufacturer"]),
      model: present(chassis["Model"]),
      serial_number: present(chassis["SerialNumber"]),
      bios_vendor: present(bios["Manufacturer"]),
      bios_version: present(bios["Version"]),
      bios_release_date: present(bios["ReleaseDate"]),
      processors: processors(Map.get(items_by_class, "CIM_Chip", [])),
      memory_bytes: memory_bytes(Map.get(items_by_class, "CIM_PhysicalMemory", []))
    }
  end

  @doc "The full firmware version: version and build (`11.8.55.3510`) when both are known."
  @spec full_firmware_version(t()) :: String.t() | nil
  def full_firmware_version(%__MODULE__{firmware_version: nil}), do: nil

  def full_firmware_version(%__MODULE__{firmware_version: version, firmware_build: nil}),
    do: version

  def full_firmware_version(%__MODULE__{firmware_version: version, firmware_build: build}),
    do: "#{version}.#{build}"

  @doc "CVE-2017-5689 verdict of the firmware (`Belgo.Amt.Vulnerability`)."
  @spec vulnerability(t()) :: Vulnerability.verdict()
  def vulnerability(%__MODULE__{} = info),
    do: Vulnerability.cve_2017_5689(full_firmware_version(info))

  defp first(items_by_class, class), do: List.first(Map.get(items_by_class, class, [])) || %{}

  defp version_of(identities, instance) do
    case Enum.find(identities, &(&1["InstanceID"] == instance)) do
      nil -> nil
      identity -> present(identity["VersionString"])
    end
  end

  defp processors(chips) do
    named = Enum.filter(chips, &String.contains?(&1["ElementName"] || "", @processor_marker))
    chips = if named == [], do: chips, else: named

    chips
    |> Enum.map(&present(&1["Version"]))
    |> Enum.reject(&is_nil/1)
  end

  defp memory_bytes([]), do: nil

  defp memory_bytes(modules) do
    capacities =
      for module <- modules,
          {capacity, ""} <- [Integer.parse(module["Capacity"] || "")],
          do: capacity

    if capacities == [], do: nil, else: Enum.sum(capacities)
  end

  defp present(nil), do: nil

  defp present(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
