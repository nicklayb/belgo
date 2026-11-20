defmodule Belgo.Amt.Target do
  @moduledoc """
  Where Belgo talks to an Intel AMT: its address, the WS-Management and redirection
  (serial over LAN) ports, whether they use TLS (only when the plain port is
  closed), and the CA file of `amt.ca_file` (`config.yaml`) required by TLS.
  """

  alias Belgo.Amt.Detection
  alias Belgo.Config.Amt, as: AmtConfig

  @enforce_keys [:address]
  defstruct [
    :address,
    :ca_file,
    wsman_tls?: false,
    redirection_tls?: false,
    wsman_port: Detection.wsman_port(false),
    redirection_port: Detection.redirection_port(false),
    timeout: %AmtConfig{}.timeout
  ]

  @type t :: %__MODULE__{
          address: String.t(),
          ca_file: Path.t() | nil,
          wsman_tls?: boolean(),
          redirection_tls?: boolean(),
          wsman_port: :inet.port_number(),
          redirection_port: :inet.port_number(),
          timeout: pos_integer()
        }

  @doc "The target of a detected AMT with the AMT settings of `config.yaml`."
  @spec new(Detection.t(), AmtConfig.t()) :: t()
  def new(%Detection{} = detection, %AmtConfig{} = config) do
    wsman_tls? = Detection.wsman_tls?(detection)
    redirection_tls? = Detection.redirection_tls?(detection)

    %__MODULE__{
      address: detection.address,
      ca_file: config.ca_file,
      wsman_tls?: wsman_tls?,
      redirection_tls?: redirection_tls?,
      wsman_port: Detection.wsman_port(wsman_tls?),
      redirection_port: Detection.redirection_port(redirection_tls?),
      timeout: config.timeout
    }
  end

  @doc "Checks that a TLS port has its CA file."
  @spec check_tls(t(), :wsman | :redirection) :: :ok | {:error, :ca_file_missing}
  def check_tls(%__MODULE__{ca_file: nil} = target, service) do
    if tls?(target, service), do: {:error, :ca_file_missing}, else: :ok
  end

  def check_tls(%__MODULE__{}, _service), do: :ok

  @doc "The WS-Management URL (`/wsman`, over HTTPS with TLS)."
  @spec wsman_url(t()) :: String.t()
  def wsman_url(%__MODULE__{} = target) do
    scheme = if target.wsman_tls?, do: "https", else: "http"
    "#{scheme}://#{host(target.address)}:#{target.wsman_port}/wsman"
  end

  defp tls?(target, :wsman), do: target.wsman_tls?
  defp tls?(target, :redirection), do: target.redirection_tls?

  defp host(address), do: if(String.contains?(address, ":"), do: "[#{address}]", else: address)
end
