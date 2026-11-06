defmodule BelgoWeb.Navigation do
  @moduledoc """
  Main menu entries. New features register here to appear in the sidebar.
  """

  use Gettext, backend: BelgoWeb.Gettext

  defmodule Item do
    @moduledoc """
    A menu entry; it is active for its path and every path below it. `badge` names
    the counter shown next to it, if any.
    """
    @enforce_keys [:label, :path, :icon]
    defstruct [:label, :path, :icon, :badge]

    @type t :: %__MODULE__{
            label: String.t(),
            path: String.t(),
            icon: String.t(),
            badge: atom() | nil
          }
  end

  @doc "Lists the menu entries in display order."
  @spec items() :: [Item.t()]
  def items do
    [
      %Item{label: gettext("Overview"), path: "/", icon: "hero-squares-2x2", badge: :overview},
      %Item{
        label: gettext("Discovery"),
        path: "/discovery",
        icon: "hero-sparkles",
        badge: :discovery
      },
      %Item{label: gettext("Devices"), path: "/devices", icon: "hero-server"},
      %Item{label: gettext("Locations"), path: "/locations", icon: "hero-map-pin"},
      %Item{label: gettext("Hosting"), path: "/hosting", icon: "hero-rectangle-stack"},
      %Item{label: gettext("Routing"), path: "/routing", icon: "hero-share"},
      %Item{label: gettext("Networks"), path: "/networks", icon: "hero-globe-alt"},
      %Item{
        label: gettext("Virtual IPs"),
        path: "/virtual-ips",
        icon: "hero-arrows-pointing-in"
      },
      %Item{label: gettext("Sync"), path: "/sync", icon: "hero-arrow-path"}
    ]
  end

  @doc """
  Computes the menu counters: Overview counts what needs fixing (inventory issues,
  divergences and provider conflicts), Discovery the devices out of the DHCP pool.
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

  @doc "Returns the counter of an item, `nil` when there is nothing to show."
  @spec badge_count(Item.t(), %{atom() => non_neg_integer()}) :: pos_integer() | nil
  def badge_count(%Item{badge: nil}, _badges), do: nil

  def badge_count(%Item{badge: badge}, badges) do
    case Map.get(badges, badge, 0) do
      0 -> nil
      count -> count
    end
  end

  @doc "Returns `true` when the item matches the current path."
  @spec active?(Item.t(), String.t()) :: boolean()
  def active?(%Item{path: "/"}, current_path), do: current_path == "/"

  def active?(%Item{path: path}, current_path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end
end
