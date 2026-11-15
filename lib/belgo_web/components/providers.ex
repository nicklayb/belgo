defmodule BelgoWeb.Components.Providers do
  @moduledoc """
  Components showing the providers configured in `providers.yaml`: the outcome of
  their last pull and last push, and the errors of an invalid file.
  """

  use BelgoWeb, :component

  alias Belgo.Discovery.State.ProviderStatus
  alias Belgo.Sync.PushReport
  alias BelgoWeb.Format

  attr(:errors, :list, required: true)

  @doc "The errors of an invalid `providers.yaml`, nothing when it is valid."
  def settings_errors(assigns) do
    ~H"""
    <.card :if={@errors != []} class="border-danger/40">
      <p class="mb-2 text-sm font-medium text-danger">{gettext("providers.yaml is invalid")}</p>
      <p :for={message <- @errors} class="font-mono text-xs">{message}</p>
    </.card>
    """
  end

  @doc "Returns `true` when the last pull of the provider failed, even partly."
  @spec failed?(ProviderStatus.t()) :: boolean()
  def failed?(%ProviderStatus{running?: true}), do: false
  def failed?(%ProviderStatus{error: error}) when not is_nil(error), do: true
  def failed?(%ProviderStatus{report: %{failures: [_failure | _failures]}}), do: true
  def failed?(%ProviderStatus{}), do: false

  attr(:provider, ProviderStatus, required: true)

  @doc """
  A provider card: mode, last pull (counts, failures, a *Refresh* button sending
  `refresh-provider` after a failure) and last push.
  """
  def provider_status(assigns) do
    ~H"""
    <div class="rounded-xl border border-border bg-surface p-4 shadow-xs">
      <div class="flex items-center justify-between">
        <p class="flex items-center gap-2 font-semibold">
          {@provider.label}
          <.badge>
            {if @provider.mode == :write, do: gettext("Read & write"), else: gettext("Read only")}
          </.badge>
        </p>
        <.badge :if={@provider.running?} tone={:accent}>{gettext("Pulling…")}</.badge>
        <.badge :if={!@provider.running? && @provider.error} tone={:danger}>
          {gettext("Failed")}
        </.badge>
        <.badge :if={!@provider.running? && !@provider.error && @provider.report} tone={:success}>
          {gettext("Up to date")}
        </.badge>
      </div>
      <p class="mt-1 text-xs text-muted">
        {gettext("Last pull: %{time}", time: Format.datetime(@provider.completed_at))}
      </p>
      <p
        :for={{service, reason} <- (@provider.report && @provider.report.failures) || []}
        :if={!@provider.error}
        class="mt-2 font-mono text-xs break-all text-danger"
      >
        {Format.label(service)}: {inspect(reason)}
      </p>
      <p :if={@provider.error} class="mt-2 font-mono text-xs break-all text-danger">
        {inspect(@provider.error)}
      </p>
      <Form.button
        :if={failed?(@provider)}
        size={:small}
        class="mt-3"
        phx-click="refresh-provider"
        phx-value-provider={@provider.key}
        title={gettext("Pull %{provider} again", provider: @provider.label)}
      >
        <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Refresh")}
      </Form.button>
      <ul :if={@provider.report} class="mt-2 space-y-0.5 text-sm">
        <li :for={{source, count} <- Enum.sort(@provider.report.counts)} class="flex justify-between">
          <span class="text-muted">{Format.source(source)}</span>
          <span class="tabular-nums">{count}</span>
        </li>
      </ul>
      <div :if={@provider.last_push} class="mt-3 border-t border-border pt-3 text-sm">
        <p class="flex items-center justify-between gap-2">
          <span class="text-muted">
            {push_target(@provider.last_push.device_id)}
          </span>
          <.push_badge result={@provider.last_push.result} />
        </p>
        <p class="mt-1 text-xs break-words text-muted">{push_summary(@provider.last_push.result)}</p>
      </div>
    </div>
    """
  end

  defp push_target(:all), do: gettext("Last push: everything")
  defp push_target(device_id), do: gettext("Last push: %{device}", device: device_id)

  attr(:result, :any, required: true)

  defp push_badge(assigns) do
    assigns = assign(assigns, :outcome, push_outcome(assigns.result))

    ~H"""
    <.badge :if={@outcome == :applied} tone={:success}>{gettext("Applied")}</.badge>
    <.badge :if={@outcome == :partial} tone={:danger}>{gettext("Partly failed")}</.badge>
    <.badge :if={@outcome == :failed} tone={:danger}>{gettext("Failed")}</.badge>
    """
  end

  defp push_outcome({:ok, %PushReport{failures: [_ | _]}}), do: :partial
  defp push_outcome({:ok, %PushReport{}}), do: :applied
  defp push_outcome({:error, _reason}), do: :failed

  defp push_summary({:ok, %PushReport{failures: []} = report}), do: PushReport.summary(report)

  defp push_summary({:ok, report}) do
    failures =
      Enum.map_join(report.failures, "; ", fn {service, reason} ->
        "#{service}: #{inspect(reason)}"
      end)

    PushReport.summary(report) <> " — " <> failures
  end

  defp push_summary({:error, reason}), do: inspect(reason)
end
