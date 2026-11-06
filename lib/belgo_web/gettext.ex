defmodule BelgoWeb.Gettext do
  use Gettext.Backend, otp_app: :belgo

  defmacro __using__(_) do
    quote do
      use Gettext, backend: BelgoWeb.Gettext
    end
  end
end
