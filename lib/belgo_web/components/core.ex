defmodule BelgoWeb.Components.Core do
  @moduledoc "Building blocks shared by every page."

  use Phoenix.Component
  use Gettext, backend: BelgoWeb.Gettext

  alias Phoenix.LiveView.JS

  @badge_tones %{
    neutral: "bg-surface-muted text-muted ring-border",
    accent: "bg-accent-soft text-accent ring-accent/20",
    success: "bg-success-soft text-success ring-success/20",
    warning: "bg-warning-soft text-warning ring-warning/20",
    danger: "bg-danger-soft text-danger ring-danger/20",
    proxmox: "bg-proxmox-soft text-proxmox ring-proxmox/25",
    docker: "bg-docker-soft text-docker ring-docker/25",
    kubernetes: "bg-kubernetes-soft text-kubernetes ring-kubernetes/25"
  }

  attr(:name, :string, required: true, doc: "a `hero-*` class")
  attr(:class, :any, default: "size-5")

  @doc "Renders a Heroicon."
  def icon(assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true"></span>
    """
  end

  attr(:title, :string, required: true)
  attr(:back, :string, default: nil, doc: "path of the parent page")
  slot(:subtitle)
  slot(:actions)
  slot(:title_suffix, doc: "rendered right after the title, e.g. a status indicator")

  @doc "Title of a page with optional back link and actions."
  def page_header(assigns) do
    ~H"""
    <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div class="min-w-0">
        <.link
          :if={@back}
          navigate={@back}
          class="mb-2 inline-flex items-center gap-1 text-sm text-muted hover:text-foreground"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> {gettext("Back")}
        </.link>
        <div class="flex min-w-0 items-center gap-3">
          <h1 class="truncate text-2xl font-semibold tracking-tight">{@title}</h1>
          {render_slot(@title_suffix)}
        </div>
        <div :if={@subtitle != []} class="mt-1 text-sm text-muted">{render_slot(@subtitle)}</div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  attr(:title, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:padded, :boolean, default: true)

  attr(:collapse_key, :string,
    default: nil,
    doc: "makes the card collapsible; its state is remembered under this key"
  )

  attr(:collapsed, :boolean, default: false, doc: "collapsed until the user opens it")
  attr(:rest, :global)
  slot(:actions)
  slot(:inner_block, required: true)

  @doc """
  A bordered surface grouping related content. With `collapse_key`, a click on its
  header collapses it; the browser remembers the choice (`Collapsible` hook), the
  default being open unless `collapsed`.
  """
  def card(%{collapse_key: key} = assigns) when is_binary(key) do
    ~H"""
    <section class={["rounded-xl border border-border bg-surface shadow-xs", @class]} {@rest}>
      <details
        id={"collapsible-#{@collapse_key}"}
        phx-hook="Collapsible"
        phx-mounted={JS.ignore_attributes("open")}
        data-collapse-key={@collapse_key}
        open={!@collapsed}
        class="group"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 rounded-xl px-5 py-3 select-none group-open:rounded-b-none group-open:border-b group-open:border-border hover:bg-surface-muted [&::-webkit-details-marker]:hidden">
          <h2 class="flex items-center gap-1.5 text-sm font-semibold">
            <.icon
              name="hero-chevron-right-mini"
              class="size-4 text-muted transition-transform group-open:rotate-90"
            />
            {@title}
          </h2>
          <div class="flex gap-2">{render_slot(@actions)}</div>
        </summary>
        <div class={@padded && "p-5"}>{render_slot(@inner_block)}</div>
      </details>
    </section>
    """
  end

  def card(assigns) do
    ~H"""
    <section class={["rounded-xl border border-border bg-surface shadow-xs", @class]} {@rest}>
      <header
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-2 border-b border-border px-5 py-3"
      >
        <h2 class="text-sm font-semibold">{@title}</h2>
        <div class="flex gap-2">{render_slot(@actions)}</div>
      </header>
      <div class={@padded && "p-5"}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr(:tone, :atom, default: :neutral, values: Map.keys(@badge_tones))
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  @doc "A small label."
  def badge(assigns) do
    assigns = assign(assigns, :tone_class, Map.fetch!(@badge_tones, assigns.tone))

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium ring-1 ring-inset whitespace-nowrap",
        @tone_class,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr(:id, :string, required: true)
  attr(:text, :string, required: true, doc: "copied to the clipboard on click")
  attr(:label, :string, default: nil, doc: "accessible label, defaults to \"Copy\"")
  attr(:class, :any, default: nil)

  @doc """
  Small icon button copying `text` to the clipboard (`belgo:copy` listener in `app.js`),
  which shows a check mark for a moment once copied.
  """
  def copy_button(assigns) do
    assigns = assign(assigns, :label, assigns.label || gettext("Copy"))

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={JS.dispatch("belgo:copy", detail: %{text: @text})}
      title={@label}
      aria-label={@label}
      data-copy-button
      class={[
        "group/copy inline-flex size-5 shrink-0 items-center justify-center rounded text-muted hover:bg-surface-muted hover:text-foreground focus-visible:ring-2 focus-visible:ring-accent focus-visible:outline-none",
        @class
      ]}
    >
      <.icon name="hero-clipboard-document-micro" class="size-3.5 group-data-copied/copy:hidden" />
      <.icon
        name="hero-check-micro"
        class="hidden size-3.5 text-success group-data-copied/copy:inline-block"
      />
    </button>
    """
  end

  attr(:icon, :string, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block)
  slot(:action)

  @doc "Placeholder shown when a list has nothing to display."
  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center px-6 py-10 text-center">
      <span class="mb-3 grid size-10 place-items-center rounded-full bg-surface-muted text-muted">
        <.icon name={@icon} />
      </span>
      <p class="font-medium">{@title}</p>
      <div :if={@inner_block != []} class="mt-1 max-w-sm text-sm text-muted">
        {render_slot(@inner_block)}
      </div>
      <div :if={@action != []} class="mt-4">{render_slot(@action)}</div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)
  slot(:detail, doc: "a short line under the label")

  @doc "A key figure linking to its page."
  def stat(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group flex items-center gap-4 rounded-xl border border-border bg-surface p-4 shadow-xs transition-colors hover:border-accent/40"
    >
      <span class="grid size-10 place-items-center rounded-lg bg-accent-soft text-accent">
        <.icon name={@icon} />
      </span>
      <div>
        <p class="text-2xl font-semibold tabular-nums">{@value}</p>
        <p class="text-sm text-muted group-hover:text-foreground">{@label}</p>
        <p :if={@detail != []} class="mt-0.5 text-xs">{render_slot(@detail)}</p>
      </div>
    </.link>
    """
  end

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil)
  attr(:row_click, :any, default: nil, doc: "function of the row returning a `JS` command")
  attr(:sort_event, :string, default: nil, doc: "event sent with `field` by sortable headers")
  attr(:sort, :any, default: nil, doc: "current `{field, :asc | :desc}`")

  slot :col, required: true do
    attr(:label, :string)
    attr(:class, :string)
    attr(:sort_field, :atom, doc: "makes the header sortable when `sort_event` is set")
    attr(:skip_row_click, :boolean, doc: "cells of this column do not trigger `row_click`")
  end

  slot(:action, doc: "per row actions, rendered on the right")

  @doc "A responsive table; secondary columns can be hidden with `class=\"hidden md:table-cell\"`."
  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-left text-sm">
        <thead class="border-b border-border text-xs uppercase tracking-wide text-muted">
          <tr>
            <th
              :for={col <- @col}
              class={["px-5 py-2.5 font-medium", col[:class]]}
              aria-sort={aria_sort(@sort, col[:sort_field])}
            >
              <button
                :if={@sort_event && col[:sort_field]}
                type="button"
                phx-click={@sort_event}
                phx-value-field={col[:sort_field]}
                class="inline-flex items-center gap-1 uppercase hover:text-foreground"
              >
                {col[:label]}
                <.icon name={sort_icon(@sort, col[:sort_field])} class="size-3" />
              </button>
              <span :if={!(@sort_event && col[:sort_field])}>{col[:label]}</span>
            </th>
            <th :if={@action != []} class="px-5 py-2.5">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} class="divide-y divide-border">
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={["align-top", @row_click && "cursor-pointer hover:bg-surface-muted/60"]}
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && !col[:skip_row_click] && @row_click.(row)}
              class={["px-5 py-3", col[:class]]}
            >
              {render_slot(col, row)}
            </td>
            <td :if={@action != []} class="px-5 py-3 text-right whitespace-nowrap">
              {render_slot(@action, row)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp aria_sort({field, :asc}, field) when not is_nil(field), do: "ascending"
  defp aria_sort({field, :desc}, field) when not is_nil(field), do: "descending"
  defp aria_sort(_sort, _field), do: nil

  defp sort_icon({field, :asc}, field), do: "hero-chevron-up-micro"
  defp sort_icon({field, :desc}, field), do: "hero-chevron-down-micro"
  defp sort_icon(_sort, _field), do: "hero-chevron-up-down-micro"

  slot :item, required: true do
    attr(:label, :string, required: true)
  end

  @doc "Label / value pairs."
  def properties(assigns) do
    ~H"""
    <dl class="divide-y divide-border">
      <div :for={item <- @item} class="grid grid-cols-3 gap-4 py-2.5 text-sm first:pt-0 last:pb-0">
        <dt class="text-muted">{item.label}</dt>
        <dd class="col-span-2 min-w-0 break-words">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  attr(:flash, :map, required: true)

  @doc "Renders info and error flash messages."
  def flash_group(assigns) do
    ~H"""
    <div class="space-y-2 empty:hidden">
      <.flash :for={kind <- [:info, :error]} kind={kind} message={Phoenix.Flash.get(@flash, kind)} />
    </div>
    """
  end

  attr(:segment, :any, required: true)

  # On one line: whitespace around segments would show in the message.
  defp flash_segment(%{segment: {:link, label, path}} = assigns) do
    assigns = assign(assigns, label: label, path: path)
    ~H|<.link navigate={@path} class="font-medium underline hover:no-underline">{@label}</.link>|
  end

  defp flash_segment(assigns), do: ~H"{@segment}"

  attr(:kind, :atom, required: true)
  attr(:message, :any, default: nil, doc: "a string or a `BelgoWeb.FlashMessage`")

  defp flash(assigns) do
    ~H"""
    <div
      :if={@message}
      id={"flash-#{@kind}"}
      role="alert"
      class={[
        "mb-4 flex items-start gap-3 rounded-lg border px-4 py-3 text-sm",
        @kind == :info && "border-success/30 bg-success-soft text-success",
        @kind == :error && "border-danger/30 bg-danger-soft text-danger"
      ]}
    >
      <.icon
        name={if @kind == :info, do: "hero-check-circle-mini", else: "hero-exclamation-circle-mini"}
        class="mt-0.5 size-5 shrink-0"
      />
      <p :if={is_binary(@message)} class="flex-1 whitespace-pre-line">{@message}</p>
      <p :if={!is_binary(@message)} class="flex-1">
        <.flash_segment :for={segment <- elem(@message, 1)} segment={segment} />
      </p>
      <button
        type="button"
        aria-label={gettext("Dismiss")}
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
      >
        <.icon name="hero-x-mark-mini" class="size-5 opacity-60 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
