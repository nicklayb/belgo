defmodule Belgo.Amt.Detection do
  @moduledoc """
  An Intel AMT (or Intel Standard Manageability) found on an address: which of its
  ports accept connections and the firmware announced by the unauthenticated
  `Server` header of its web server. Live data, never persisted.

  Measured on the owner's network, the header is one of
  `Intel(R) Active Management Technology 11.8.55.3510`,
  `Intel(R) Standard Manageability 9.1.45` or a bare `AMT`.
  """

  @wsman_port 16_992
  @wsman_tls_port 16_993
  @redirection_port 16_994
  @redirection_tls_port 16_995
  @ports [@wsman_port, @wsman_tls_port, @redirection_port, @redirection_tls_port]
  @products [
    {"Intel(R) Active Management Technology", :amt},
    {"Intel(R) Standard Manageability", :standard_manageability}
  ]
  @bare_server_header "AMT"

  @enforce_keys [:address, :open_ports]
  defstruct [:address, :open_ports, :product, :version]

  @type product :: :amt | :standard_manageability
  @type t :: %__MODULE__{
          address: String.t(),
          open_ports: [:inet.port_number()],
          product: product() | nil,
          version: String.t() | nil
        }

  @doc "The TCP ports of Intel AMT (WS-Management and redirection, plain and TLS)."
  @spec ports() :: [:inet.port_number()]
  def ports, do: @ports

  @doc "The WS-Management port: plain HTTP (16992) or TLS (16993)."
  @spec wsman_port(boolean()) :: :inet.port_number()
  def wsman_port(false = _tls?), do: @wsman_port
  def wsman_port(true = _tls?), do: @wsman_tls_port

  @doc "The redirection (serial over LAN) port: plain (16994) or TLS (16995)."
  @spec redirection_port(boolean()) :: :inet.port_number()
  def redirection_port(false = _tls?), do: @redirection_port
  def redirection_port(true = _tls?), do: @redirection_tls_port

  @doc """
  Reads a `Server` header: `{:ok, product, version}` when it is Intel AMT's (`version`
  is `nil` for the bare `AMT` header), `:error` otherwise.
  """
  @spec parse_server_header(String.t() | nil) :: {:ok, product(), String.t() | nil} | :error
  def parse_server_header(nil), do: :error

  def parse_server_header(header) do
    header = String.trim(header)

    if header == @bare_server_header,
      do: {:ok, :amt, nil},
      else: parse_product(header)
  end

  defp parse_product(header) do
    Enum.find_value(@products, :error, fn {prefix, product} ->
      case String.split(header, prefix, parts: 2) do
        ["", version] -> {:ok, product, blank_to_nil(String.trim(version))}
        _other -> nil
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  @doc "Whether WS-Management is only reachable over TLS (16992 closed, 16993 open)."
  @spec wsman_tls?(t()) :: boolean()
  def wsman_tls?(%__MODULE__{open_ports: open_ports}),
    do: @wsman_port not in open_ports and @wsman_tls_port in open_ports

  @doc "Whether serial over LAN is only reachable over TLS (16994 closed, 16995 open)."
  @spec redirection_tls?(t()) :: boolean()
  def redirection_tls?(%__MODULE__{open_ports: open_ports}),
    do: @redirection_port not in open_ports and @redirection_tls_port in open_ports

  @doc "Whether a redirection port (serial over LAN) accepts connections."
  @spec serial_over_lan?(t()) :: boolean()
  def serial_over_lan?(%__MODULE__{open_ports: open_ports}),
    do: @redirection_port in open_ports or @redirection_tls_port in open_ports

  @doc "A readable name of the product and firmware, e.g. `Intel AMT 11.8.55.3510`."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{product: product, version: version}) do
    name = if product == :standard_manageability, do: "Intel ISM", else: "Intel AMT"
    Enum.join(Enum.reject([name, version], &is_nil/1), " ")
  end
end
