defmodule BelgoWeb.Components.Discovery do
  @moduledoc "Components rendering discovery results."

  use Phoenix.Component
  use Gettext, backend: BelgoWeb.Gettext

  import BelgoWeb.Components.Core

  alias Belgo.Discovery.Correlation.Divergence
  alias Belgo.Discovery.Observation
  alias BelgoWeb.Format

  attr(:observations, :list, required: true)

  @doc "Distinct `provider · source` badges of observations."
  def source_badges(assigns) do
    assigns =
      assign(
        assigns,
        :sources,
        assigns.observations
        |> Enum.map(&{&1.provider, &1.source})
        |> Enum.uniq()
      )

    ~H"""
    <span class="inline-flex flex-wrap gap-1">
      <.badge :for={{provider, source} <- @sources} tone={:accent}>
        {Format.label(provider)} · {Format.source(source)}
      </.badge>
    </span>
    """
  end

  attr(:observations, :list, required: true)

  @doc "What each provider reported, one line per observation."
  def observation_list(assigns) do
    ~H"""
    <ul class="divide-y divide-border text-sm">
      <li :for={%Observation{} = observation <- @observations} class="space-y-1 px-5 py-3">
        <.source_badges observations={[observation]} />
        <dl class="grid grid-cols-[7rem_1fr] gap-x-3 gap-y-0.5">
          <.observation_field
            :if={observation.name}
            label={gettext("Name")}
            value={observation.name}
          />
          <.observation_field
            :if={observation.reference && observation.kind == :location}
            label={gettext("Reference")}
            value={observation.reference}
          />
          <.observation_field
            :if={observation.hostname}
            label={gettext("Name")}
            value={Observation.fqdn(observation)}
          />
          <.observation_field :if={observation.mac} label={gettext("MAC")} value={observation.mac} />
          <.observation_field :if={observation.ip} label={gettext("IP")} value={observation.ip} />
          <.observation_field
            :if={observation.cidr}
            label={gettext("Range")}
            value={observation.cidr}
          />
          <.observation_field
            :if={observation.gateway}
            label={gettext("Gateway")}
            value={observation.gateway}
          />
          <.observation_field
            :if={observation.description}
            label={gettext("Description")}
            value={observation.description}
          />
        </dl>
      </li>
    </ul>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp observation_field(assigns) do
    ~H"""
    <dt class="text-muted">{@label}</dt>
    <dd class="font-mono text-xs leading-5 break-all">{@value}</dd>
    """
  end

  attr(:divergences, :list, required: true)

  @doc "Differences between providers and the inventory."
  def divergence_list(assigns) do
    ~H"""
    <ul class="divide-y divide-border text-sm">
      <li :for={%Divergence{} = divergence <- @divergences} class="flex items-start gap-3 px-5 py-3">
        <.icon name="hero-arrows-right-left-mini" class="mt-0.5 size-4 shrink-0 text-warning" />
        <div class="min-w-0">
          <.badge>{Format.label(divergence.provider)}</.badge>
          <span class="ml-1">{divergence.message}</span>
        </div>
      </li>
    </ul>
    """
  end
end
