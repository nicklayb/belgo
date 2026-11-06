defmodule Belgo.PortScan.Ports do
  @moduledoc "The TCP ports checked on devices: common services of a homelab, with their name."

  @service_by_port %{
    21 => "FTP",
    22 => "SSH",
    23 => "Telnet",
    25 => "SMTP",
    53 => "DNS",
    80 => "HTTP",
    110 => "POP3",
    111 => "RPC",
    139 => "NetBIOS",
    143 => "IMAP",
    443 => "HTTPS",
    445 => "SMB",
    548 => "AFP",
    554 => "RTSP",
    631 => "IPP (printing)",
    853 => "DNS over TLS",
    993 => "IMAPS",
    1883 => "MQTT",
    2049 => "NFS",
    2375 => "Docker",
    2376 => "Docker (TLS)",
    3000 => "HTTP (3000)",
    3306 => "MySQL",
    3389 => "RDP",
    5000 => "HTTP (5000)",
    5432 => "PostgreSQL",
    5900 => "VNC",
    6379 => "Redis",
    6443 => "Kubernetes API",
    8006 => "Proxmox",
    8080 => "HTTP (8080)",
    8123 => "Home Assistant",
    8443 => "HTTPS (8443)",
    8883 => "MQTT (TLS)",
    9000 => "HTTP (9000)",
    9090 => "Prometheus",
    9100 => "Node exporter / printing",
    10_250 => "Kubelet",
    32_400 => "Plex"
  }

  @doc "The checked ports, in increasing order."
  @spec all() :: [:inet.port_number()]
  def all, do: Enum.sort(Map.keys(@service_by_port))

  @doc "The usual service of a port."
  @spec service(:inet.port_number()) :: String.t() | nil
  def service(port), do: Map.get(@service_by_port, port)
end
