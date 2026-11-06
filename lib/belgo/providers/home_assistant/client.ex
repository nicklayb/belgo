defmodule Belgo.Providers.HomeAssistant.Client do
  @moduledoc "Behaviour of the Home Assistant access, so tests never reach the network."

  alias Belgo.Providers.HomeAssistant.Config

  @typedoc "Raw registry entries, as returned by Home Assistant."
  @type registries :: %{floors: [map()], areas: [map()]}

  @doc "Lists the floor and area registries."
  @callback registries(Config.t()) :: {:ok, registries()} | {:error, any()}
end
