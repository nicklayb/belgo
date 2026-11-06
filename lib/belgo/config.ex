defmodule Belgo.Config do
  @moduledoc """
  Global settings of Belgo, read from `config.yaml` next to the inventory files. A
  missing file or key means the default value.

      version: 1
      theme: auto             # auto (follows the system), light or dark
      ping:
        cache_duration: 15m   # a result is reused for that long
        timeout: 2s           # how long to wait for an answer
      git:                    # version the data directory (absent: disabled)
        commit_delay: 5m      # commit once the files are left alone that long
        remote: git@github.com:simpson/homelab.git   # optional, pushed, never pulled
        push_interval: 1h
      wake_on_lan:
        ping_interval: 5s     # pings the woken device this often
        timeout: 1m           # gives up after that long
      port_scan:
        cache_duration: 1h    # open ports are reused for that long
        timeout: 1s           # how long to wait for each port
      plan:
        autosave_delay: 5s    # the plan editor saves once changes are left alone

  Read when needed, so edits apply without restart.
  """

  require Logger

  alias Belgo.Config.Git
  alias Belgo.Config.Ping
  alias Belgo.Config.Plan
  alias Belgo.Config.PortScan
  alias Belgo.Config.WakeOnLan
  alias Belgo.Duration

  @file_name "config.yaml"
  @format_version 1
  @minimum_cache_duration_milliseconds 0
  @minimum_timeout_milliseconds 1
  @minimum_commit_delay_milliseconds 0
  @minimum_push_interval_milliseconds 1_000
  @minimum_ping_interval_milliseconds 1_000
  @git_text_keys [:author_name, :author_email, :remote, :branch]

  @themes %{"auto" => :auto, "light" => :light, "dark" => :dark}

  defstruct theme: :auto,
            ping: %Ping{},
            git: nil,
            wake_on_lan: %WakeOnLan{},
            port_scan: %PortScan{},
            plan: %Plan{}

  @type theme :: :auto | :light | :dark
  @type t :: %__MODULE__{
          theme: theme(),
          ping: Ping.t(),
          git: Git.t() | nil,
          wake_on_lan: WakeOnLan.t(),
          port_scan: PortScan.t(),
          plan: Plan.t()
        }

  @doc "Reads `config.yaml` from the configured data directory, defaults when invalid."
  @spec current() :: t()
  def current do
    directory =
      :belgo
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:directory)

    case load(directory) do
      {:ok, config} ->
        config

      {:error, messages} ->
        Logger.error("[config] invalid, defaults used:\n  " <> Enum.join(messages, "\n  "))
        %__MODULE__{}
    end
  end

  @doc "Reads and validates `config.yaml` from the inventory directory."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def load(directory) do
    path = Path.join(directory, @file_name)

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, document} -> parse(document)
        {:error, error} -> {:error, ["#{@file_name}: #{Exception.message(error)}"]}
      end
    else
      {:ok, %__MODULE__{}}
    end
  end

  @doc "Validates a parsed `config.yaml` document."
  @spec parse(any()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(%{"version" => @format_version} = document) do
    with {:ok, theme} <- parse_theme(Map.get(document, "theme", "auto")),
         {:ok, ping} <- parse_ping(Map.get(document, "ping") || %{}),
         {:ok, git} <- parse_git(document),
         {:ok, wake_on_lan} <-
           parse_durations(document, "wake_on_lan", WakeOnLan,
             ping_interval: @minimum_ping_interval_milliseconds,
             timeout: @minimum_timeout_milliseconds
           ),
         {:ok, port_scan} <-
           parse_durations(document, "port_scan", PortScan,
             cache_duration: @minimum_cache_duration_milliseconds,
             timeout: @minimum_timeout_milliseconds
           ),
         {:ok, plan} <-
           parse_durations(document, "plan", Plan,
             autosave_delay: @minimum_commit_delay_milliseconds
           ) do
      {:ok,
       %__MODULE__{
         theme: theme,
         ping: ping,
         git: git,
         wake_on_lan: wake_on_lan,
         port_scan: port_scan,
         plan: plan
       }}
    end
  end

  def parse(nil), do: {:ok, %__MODULE__{}}
  def parse(_document), do: {:error, ["#{@file_name}: expected `version: #{@format_version}`"]}

  defp parse_theme(name) do
    case Map.fetch(@themes, name) do
      {:ok, theme} -> {:ok, theme}
      :error -> {:error, ["#{@file_name}: theme must be auto, light or dark"]}
    end
  end

  defp parse_ping(options) when is_map(options) do
    defaults = %Ping{}

    collect(Ping,
      cache_duration:
        duration(
          options,
          "ping.cache_duration",
          defaults.cache_duration,
          @minimum_cache_duration_milliseconds
        ),
      timeout: duration(options, "ping.timeout", defaults.timeout, @minimum_timeout_milliseconds)
    )
  end

  defp parse_ping(_options), do: {:error, ["#{@file_name}: ping must be a map"]}

  defp parse_git(%{"git" => nil}), do: parse_git(%{"git" => %{}})

  defp parse_git(%{"git" => options}) when is_map(options) do
    defaults = %Git{}

    durations = [
      commit_delay:
        duration(
          options,
          "git.commit_delay",
          defaults.commit_delay,
          @minimum_commit_delay_milliseconds
        ),
      push_interval:
        duration(
          options,
          "git.push_interval",
          defaults.push_interval,
          @minimum_push_interval_milliseconds
        )
    ]

    texts = for key <- @git_text_keys, do: {key, text(options, key, Map.fetch!(defaults, key))}

    collect(Git, durations ++ texts)
  end

  defp parse_git(%{"git" => _options}), do: {:error, ["#{@file_name}: git must be a map"]}
  defp parse_git(_document), do: {:ok, nil}

  # A section made of durations only, each with its minimum (milliseconds).
  defp parse_durations(document, section, module, minimum_by_key) do
    case Map.get(document, section) || %{} do
      options when is_map(options) ->
        defaults = struct!(module)

        collect(
          module,
          for {key, minimum} <- minimum_by_key do
            {key, duration(options, "#{section}.#{key}", Map.fetch!(defaults, key), minimum)}
          end
        )

      _invalid ->
        {:error, ["#{@file_name}: #{section} must be a map"]}
    end
  end

  defp collect(module, results) do
    case for({_key, {:error, message}} <- results, do: message) do
      [] -> {:ok, struct!(module, for({key, {:ok, value}} <- results, do: {key, value}))}
      messages -> {:error, messages}
    end
  end

  defp duration(options, path, default, minimum) do
    key = List.last(String.split(path, "."))

    case Map.fetch(options, key) do
      :error ->
        {:ok, default}

      {:ok, value} ->
        case Duration.parse(value) do
          {:ok, milliseconds} when milliseconds >= minimum -> {:ok, milliseconds}
          _invalid -> {:error, "#{@file_name}: #{path} must look like 30s, 15m or 1h"}
        end
    end
  end

  defp text(options, key, default) do
    case Map.get(options, Atom.to_string(key)) do
      nil -> {:ok, default}
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, "#{@file_name}: git.#{key} must be a non empty text"}
    end
  end
end
