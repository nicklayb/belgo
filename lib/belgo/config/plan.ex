defmodule Belgo.Config.Plan do
  @moduledoc "Settings of the plan editor (milliseconds): changes are saved once left alone for `autosave_delay`."

  @default_autosave_delay_milliseconds 5_000

  defstruct autosave_delay: @default_autosave_delay_milliseconds

  @type t :: %__MODULE__{autosave_delay: non_neg_integer()}
end
