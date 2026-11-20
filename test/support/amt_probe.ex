defmodule Belgo.Fixtures.AmtProbe do
  @moduledoc "AMT probe without network: Burns Node (10.0.0.10) runs Intel AMT 11.8.55.3510."

  alias Belgo.Amt.Detection

  @doc "Answers like `Belgo.Amt.Probe.detect/3`."
  @spec detect(String.t(), [:inet.port_number()], pos_integer()) :: Detection.t() | nil
  def detect("10.0.0.10" = address, open_ports, _timeout) do
    if 16_992 in open_ports do
      %Detection{
        address: address,
        open_ports: Enum.filter(open_ports, &(&1 in Detection.ports())),
        product: :amt,
        version: "11.8.55.3510"
      }
    end
  end

  def detect(_address, _open_ports, _timeout), do: nil
end
