defmodule BelgoWeb.Navigation do
  @moduledoc """
  Main menu entries. New features register here to appear in the sidebar.
  """

  use Gettext, backend: BelgoWeb.Gettext

  defmodule Item do
    @moduledoc """
    A menu entry; it is active for its path and every path below it. `badges` name
    the counters shown next to it.
    """
    @enforce_keys [:label, :path, :icon]
    defstruct [:label, :path, :icon, badges: []]

    @type t :: %__MODULE__{
            label: String.t(),
            path: String.t(),
            icon: String.t(),
            badges: [atom()]
          }
  end

  defmodule Section do
    @moduledoc "A group of menu entries under a title (`nil`: no title)."
    @enforce_keys [:items]
    defstruct [:title, :items]

    @type t :: %__MODULE__{title: String.t() | nil, items: [BelgoWeb.Navigation.Item.t()]}
  end

  @doc "Lists the menu sections in display order."
  @spec sections() :: [Section.t()]
  def sections do
    [
      %Section{
        items: [
          %Item{
            label: gettext("Overview"),
            path: "/",
            icon: "hero-squares-2x2",
            badges: [:overview, :discovery]
          }
        ]
      },
      %Section{
        title: gettext("Data"),
        items: [
          %Item{label: gettext("Devices"), path: "/devices", icon: "hero-server"},
          %Item{
            label: gettext("Virtual IPs"),
            path: "/virtual-ips",
            icon: "hero-arrows-pointing-in"
          },
          %Item{label: gettext("Locations"), path: "/locations", icon: "hero-map-pin"},
          %Item{label: gettext("Networks"), path: "/networks", icon: "hero-globe-alt"}
        ]
      },
      %Section{
        title: gettext("Visualization"),
        items: [
          %Item{label: gettext("Plan"), path: "/plan", icon: "hero-home-modern"},
          %Item{label: gettext("Hosting"), path: "/hosting", icon: "hero-rectangle-stack"},
          %Item{label: gettext("Routing"), path: "/routing", icon: "hero-share"}
        ]
      },
      %Section{
        title: gettext("Providers"),
        items: [%Item{label: gettext("Synchronization"), path: "/sync", icon: "hero-arrow-path"}]
      }
    ]
  end

  @doc "Lists every menu entry in display order."
  @spec items() :: [Item.t()]
  def items, do: Enum.flat_map(sections(), & &1.items)

  @doc """
  Computes the menu counters: `overview` counts what needs fixing (inventory issues,
  divergences and provider conflicts), `discovery` the devices out of the DHCP pool.
  """
  @spec badges(Belgo.Inventory.Snapshot.t(), Belgo.Discovery.State.t()) :: %{
          atom() => non_neg_integer()
        }
  def badges(snapshot, %Belgo.Discovery.State{correlation: correlation}) do
    %{
      overview:
        length(Belgo.Inventory.issues(snapshot)) + length(correlation.divergences) +
          length(Belgo.Discovery.Correlation.unowned_conflicts(correlation)),
      discovery: length(correlation.out_of_dhcp_devices)
    }
  end

  @doc "The counters of an item worth showing (non zero), as `{badge, count}`."
  @spec badge_counts(Item.t(), %{atom() => non_neg_integer()}) :: [{atom(), pos_integer()}]
  def badge_counts(%Item{badges: names}, badges) do
    for name <- names, count = Map.get(badges, name, 0), count > 0, do: {name, count}
  end

  @doc "What a counter counts, for its tooltip."
  @spec badge_label(atom()) :: String.t()
  def badge_label(:overview), do: gettext("Issues to fix")
  def badge_label(:discovery), do: gettext("Devices out of DHCP")
  def badge_label(_badge), do: ""

  @doc "Returns `true` when the item matches the current path."
  @spec active?(Item.t(), String.t()) :: boolean()
  def active?(%Item{path: "/"}, current_path), do: current_path == "/"

  def active?(%Item{path: path}, current_path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end
end
