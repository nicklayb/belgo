defmodule Belgo.Amt.Probe do
  @moduledoc """
  Confirms that open AMT ports belong to Intel AMT: one unauthenticated `GET /` on
  the WS-Management port (16992, else 16993 over TLS) whose `Server` header must be
  AMT's (`Belgo.Amt.Detection.parse_server_header/1`). Nothing is logged in. The TLS
  probe does not verify the certificate: it sends nothing secret and only reads a
  header.

  Not `HEAD`: measured on the owner's AMT 11.8, its `HEAD` answer carries a chunked
  terminator (`0\\r\\n\\r\\n`) that the HTTP client rejects; `GET /` answers a
  `303` to `/logon.htm` with an empty body (not followed).
  """

  alias Belgo.Amt.Detection

  @doc """
  Returns the detection of the address when its open ports include an AMT
  WS-Management port answering with AMT's `Server` header, `nil` otherwise. Waits at
  most `timeout` milliseconds.
  """
  @spec detect(String.t(), [:inet.port_number()], pos_integer()) :: Detection.t() | nil
  def detect(address, open_ports, timeout) do
    amt_ports = Enum.filter(open_ports, &(&1 in Detection.ports()))

    with tls? when is_boolean(tls?) <- wsman_tls(amt_ports),
         {:ok, product, version} <-
           server(address, Detection.wsman_port(tls?), tls?, timeout) do
      %Detection{address: address, open_ports: amt_ports, product: product, version: version}
    else
      _not_amt -> nil
    end
  end

  @doc """
  Reads the `Server` header of the web server at `address:port`: `{:ok, product,
  version}` when it is AMT's, `:error` otherwise (or without answer).
  """
  @spec server(String.t(), :inet.port_number(), boolean(), pos_integer()) ::
          {:ok, Detection.product(), String.t() | nil} | :error
  def server(address, port, tls?, timeout) do
    scheme = if tls?, do: "https", else: "http"

    request =
      Req.new(
        url: "#{scheme}://#{host(address)}:#{port}/",
        receive_timeout: timeout,
        retry: false,
        redirect: false,
        connect_options: [timeout: timeout, transport_opts: transport_options(tls?)]
      )

    case Req.get(request) do
      {:ok, %Req.Response{} = response} ->
        response
        |> Req.Response.get_header("server")
        |> List.first()
        |> Detection.parse_server_header()

      {:error, _exception} ->
        :error
    end
  end

  defp wsman_tls(ports) do
    cond do
      Detection.wsman_port(false) in ports -> false
      Detection.wsman_port(true) in ports -> true
      true -> nil
    end
  end

  defp transport_options(false = _tls?), do: []
  defp transport_options(true = _tls?), do: [verify: :verify_none]

  defp host(address), do: if(String.contains?(address, ":"), do: "[#{address}]", else: address)
end
