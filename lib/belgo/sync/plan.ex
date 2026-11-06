defmodule Belgo.Sync.Plan do
  @moduledoc """
  Computes the changes to apply to an external system (AdGuard Home, OPNsense,
  Omada) from the desired and actual entries.

  Synchronisation is **never destructive**:

    * missing entries are created, existing ones updated when they differ
    * there is no delete action: entries unknown to the inventory are left untouched

  Entries are matched by `key` (e.g. the DNS name or the MAC address) and compared
  with `comparable`, so fields the inventory does not manage are ignored.
  """

  defmodule Change do
    @moduledoc "One change to apply on a target."

    @enforce_keys [:action, :key, :desired]
    defstruct [:action, :key, :desired, :actual]

    @type t :: %__MODULE__{action: :create | :update, key: any(), desired: any(), actual: any()}
  end

  @type options :: [
          key: (any() -> any()),
          comparable: (any() -> any())
        ]

  @doc """
  Lists the changes turning `actual` into `desired`, sorted by key.

  Options:

    * `:key` – identifies an entry on both sides (required)
    * `:comparable` – projection compared to detect differences, defaults to identity
  """
  @spec build([any()], [any()], options()) :: [Change.t()]
  def build(desired, actual, options) do
    key = Keyword.fetch!(options, :key)
    comparable = Keyword.get(options, :comparable, &Function.identity/1)
    actual_by_key = Map.new(actual, &{key.(&1), &1})

    desired
    |> Enum.flat_map(fn desired_entry ->
      entry_key = key.(desired_entry)

      case Map.fetch(actual_by_key, entry_key) do
        {:ok, actual_entry} ->
          update(entry_key, desired_entry, actual_entry, comparable)

        :error ->
          [%Change{action: :create, key: entry_key, desired: desired_entry}]
      end
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp update(entry_key, desired_entry, actual_entry, comparable) do
    if comparable.(desired_entry) == comparable.(actual_entry),
      do: [],
      else: [
        %Change{action: :update, key: entry_key, desired: desired_entry, actual: actual_entry}
      ]
  end
end
