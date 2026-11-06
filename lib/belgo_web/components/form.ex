defmodule BelgoWeb.Components.Form do
  @moduledoc "Form controls sharing the same look and error display."

  use Phoenix.Component
  use Gettext, backend: BelgoWeb.Gettext

  @control_class "block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm text-foreground ring-1 ring-inset ring-border placeholder:text-muted focus:ring-2 focus:ring-accent focus:outline-none disabled:bg-surface-muted disabled:text-muted"
  @error_control_class "ring-danger focus:ring-danger"

  @button_variants %{
    primary: "bg-accent text-accent-foreground hover:bg-accent/90 shadow-xs",
    secondary:
      "bg-surface text-foreground ring-1 ring-inset ring-border hover:bg-surface-muted shadow-xs",
    ghost: "text-muted hover:bg-surface-muted hover:text-foreground",
    danger: "text-danger hover:bg-danger-soft"
  }
  @button_sizes %{
    small: "px-2 py-1 text-xs gap-1",
    normal: "px-3 py-2 text-sm gap-1.5"
  }

  attr(:field, Phoenix.HTML.FormField, required: true)
  attr(:label, :string, default: nil)
  attr(:hint, :string, default: nil)
  attr(:type, :string, default: "text", values: ~w(text number textarea select checkbox))

  attr(:options, :list,
    default: [],
    doc: "select options, as for `Phoenix.HTML.Form.options_for_select/2`"
  )

  attr(:prompt, :string, default: nil, doc: "select blank option")
  attr(:value, :any, default: nil, doc: "overrides the field value")
  attr(:class, :any, default: nil)

  attr(:rest, :global,
    include: ~w(autocomplete disabled placeholder rows step min max autofocus list)
  )

  @doc "A labelled input bound to a form field, displaying its errors once used."
  def input(%{type: "checkbox"} = assigns) do
    assigns = prepare(assigns)

    ~H"""
    <div class={@class}>
      <input type="hidden" name={@field.name} value="false" />
      <label class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          id={@field.id}
          name={@field.name}
          value="true"
          checked={Phoenix.HTML.Form.normalize_value("checkbox", @value)}
          class="size-4 rounded border-border accent-(--color-accent)"
          {@rest}
        />
        {@label}
      </label>
      <.errors errors={@errors} />
    </div>
    """
  end

  def input(assigns) do
    assigns = prepare(assigns)

    ~H"""
    <div class={@class}>
      <label :if={@label} for={@field.id} class="mb-1 block text-sm font-medium">{@label}</label>
      <.control {assigns} />
      <p :if={@hint && @errors == []} class="mt-1 text-xs text-muted">{@hint}</p>
      <.errors errors={@errors} />
    </div>
    """
  end

  defp control(%{type: "select"} = assigns) do
    ~H"""
    <select id={@field.id} name={@field.name} class={[@control_class, "pr-8"]} {@rest}>
      <option :if={@prompt} value="">{@prompt}</option>
      {Phoenix.HTML.Form.options_for_select(@options, @value)}
    </select>
    """
  end

  defp control(%{type: "textarea"} = assigns) do
    ~H"""
    <textarea id={@field.id} name={@field.name} class={@control_class} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
    """
  end

  defp control(assigns) do
    ~H"""
    <input
      type={@type}
      id={@field.id}
      name={@field.name}
      value={Phoenix.HTML.Form.normalize_value(@type, @value)}
      class={@control_class}
      {@rest}
    />
    """
  end

  attr(:field, Phoenix.HTML.FormField, required: true)
  attr(:label, :string, required: true)
  attr(:options, :list, required: true, doc: "`{label, value}` tuples")

  @doc "A group of checkboxes submitting a list of values."
  def checkbox_group(assigns) do
    assigns =
      assigns
      |> assign(
        :selected,
        assigns.field.value
        |> List.wrap()
        |> Enum.map(&to_string/1)
      )
      |> assign(:errors, visible_errors(assigns.field))

    ~H"""
    <fieldset>
      <legend class="mb-1 block text-sm font-medium">{@label}</legend>
      <input type="hidden" name={@field.name <> "[]"} value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={{label, value} <- @options}
          class="flex cursor-pointer items-center gap-2 rounded-md px-3 py-1.5 text-sm ring-1 ring-inset ring-border has-checked:bg-accent-soft has-checked:text-accent has-checked:ring-accent/40"
        >
          <input
            type="checkbox"
            name={@field.name <> "[]"}
            value={value}
            checked={to_string(value) in @selected}
            class="sr-only"
          />
          {label}
        </label>
      </div>
      <.errors errors={@errors} />
    </fieldset>
    """
  end

  attr(:type, :string, default: "button")
  attr(:variant, :atom, default: :secondary, values: Map.keys(@button_variants))
  attr(:size, :atom, default: :normal, values: Map.keys(@button_sizes))
  attr(:navigate, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ~w(disabled form name value))
  slot(:inner_block, required: true)

  @doc "A button, or a link styled as one when `navigate` is given."
  def button(assigns) do
    assigns =
      assign(assigns, :button_class, [
        "inline-flex items-center justify-center rounded-md font-medium transition-colors disabled:opacity-50 phx-submit-loading:opacity-70",
        Map.fetch!(@button_variants, assigns.variant),
        Map.fetch!(@button_sizes, assigns.size),
        assigns.class
      ])

    ~H"""
    <.link :if={@navigate} navigate={@navigate} class={@button_class} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <button :if={!@navigate} type={@type} class={@button_class} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:errors, :list, required: true)

  @doc "Renders already translated error messages."
  def errors(assigns) do
    ~H"""
    <p :for={error <- @errors} class="mt-1 text-xs text-danger">{error}</p>
    """
  end

  @doc "Translates the errors of a field, only once the user interacted with it."
  @spec visible_errors(Phoenix.HTML.FormField.t()) :: [String.t()]
  def visible_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field),
      do: Enum.map(field.errors, &Box.Ecto.Changeset.format_error(&1, gettext: BelgoWeb.Gettext)),
      else: []
  end

  defp prepare(assigns) do
    errors = visible_errors(assigns.field)

    assigns
    |> assign(:errors, errors)
    |> assign(:value, assigns.value || assigns.field.value)
    |> assign(:control_class, [@control_class, errors != [] && @error_control_class])
  end

  @doc """
  Returns `true` when a field has no value yet, e.g. the label of a just added list
  entry (used to focus it when it appears with `phx-mounted={JS.focus()}`).
  """
  @spec blank?(Phoenix.HTML.FormField.t()) :: boolean()
  def blank?(%Phoenix.HTML.FormField{value: value}), do: value in [nil, ""]
end
