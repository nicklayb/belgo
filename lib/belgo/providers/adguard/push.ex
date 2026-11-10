defmodule Belgo.Providers.Adguard.Push do
  @moduledoc """
  Plans the AdGuard Home persistent clients needed for a desired state. Pure
  functions only.

  Each device becomes a client named after it, identified by all its MAC and IP
  addresses. An existing client is matched by a shared identifier, or else by name.
  Missing clients are added, differing ones updated, none deleted.

  AdGuard Home replaces the whole client on update, so updates send the existing
  client back with only the managed fields changed:

    * `name` – the device name
    * `ids` – the device MAC and IP addresses; other identifiers (ClientIDs, CIDRs)
      are kept
    * `tags` – the `device_*` tag follows the device kind; Belgo tags that AdGuard
      supports are added; other existing tags are kept

  AdGuard Home rejects unknown tags and identifiers or names used by another client,
  so such conflicts are skipped and reported instead of sent.
  """

  alias Belgo.Network.IpAddress
  alias Belgo.Network.MacAddress
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.DesiredState.Client

  @add_path "/control/clients/add"
  @update_path "/control/clients/update"
  @device_tag_prefix "device_"
  @device_tag_by_kind %{
    workstation: "device_pc",
    laptop: "device_laptop",
    phone: "device_phone",
    tablet: "device_tablet",
    media: "device_tv",
    gaming: "device_gameconsole",
    printer: "device_printer",
    camera: "device_camera"
  }
  @default_device_tag "device_other"

  defmodule Operation do
    @moduledoc "One write to AdGuard Home."
    @enforce_keys [:path, :body, :summary]
    defstruct [:path, :body, :summary]

    @type t :: %__MODULE__{path: String.t(), body: map(), summary: String.t()}
  end

  @type plan :: %{operations: [Operation.t()], skipped: [String.t()]}

  @doc "Returns `true` when the desired state has clients to write."
  @spec needed?(DesiredState.t()) :: boolean()
  def needed?(%DesiredState{clients: clients}), do: clients != []

  @doc "Plans the client writes from the `GET /control/clients` document."
  @spec plan(DesiredState.t(), map()) :: plan()
  def plan(%DesiredState{clients: desired}, document) do
    actual = Enum.map(list_of(document, "clients"), &index_client/1)
    supported_tags = MapSet.new(Map.get(document, "supported_tags") || [])

    {operations, skipped} =
      Enum.reduce(desired, {[], []}, fn client, {operations, skipped} ->
        case client_operation(client, actual, supported_tags) do
          {:ok, nil} -> {operations, skipped}
          {:ok, operation} -> {[operation | operations], skipped}
          {:skip, message} -> {operations, [message | skipped]}
        end
      end)

    %{operations: Enum.reverse(operations), skipped: Enum.reverse(skipped)}
  end

  defp index_client(client) do
    ids = List.wrap(client["ids"])

    %{
      data: client,
      name: client["name"],
      managed_ids: MapSet.new(Enum.flat_map(ids, &managed_id/1))
    }
  end

  defp client_operation(%Client{} = client, actual, supported_tags) do
    desired_ids = MapSet.new(client.ids)
    by_id = Enum.filter(actual, &(not MapSet.disjoint?(&1.managed_ids, desired_ids)))
    by_name = Enum.filter(actual, &same_name?(&1.name, client.name))

    case Enum.uniq_by(by_id ++ by_name, & &1.name) do
      [] ->
        create(client, actual, supported_tags)

      [existing] ->
        update(client, existing, actual, supported_tags)

      several ->
        {:skip,
         "#{client.name}: matches several AdGuard clients (#{Enum.map_join(several, ", ", & &1.name)})"}
    end
  end

  defp create(client, actual, supported_tags) do
    with :ok <- ensure_free_ids(client, nil, actual) do
      body = %{
        "name" => client.name,
        "ids" => client.ids,
        "tags" => tags(client, [], supported_tags),
        "use_global_settings" => true,
        "use_global_blocked_services" => true
      }

      {:ok,
       %Operation{
         path: @add_path,
         body: body,
         summary: "create client #{client.name} (#{Enum.join(client.ids, ", ")})"
       }}
    end
  end

  defp update(client, existing, actual, supported_tags) do
    current_ids = List.wrap(existing.data["ids"])
    unmanaged_ids = Enum.filter(current_ids, &(managed_id(&1) == []))
    current_tags = List.wrap(existing.data["tags"])

    data =
      existing.data
      |> Map.put("name", client.name)
      |> Map.put("ids", client.ids ++ unmanaged_ids)
      |> Map.put("tags", tags(client, current_tags, supported_tags))

    cond do
      comparable(data) == comparable(existing.data) ->
        {:ok, nil}

      (conflict = ensure_free_ids(client, existing, actual)) != :ok ->
        conflict

      true ->
        {:ok,
         %Operation{
           path: @update_path,
           body: %{"name" => existing.name, "data" => data},
           summary: "update client #{existing.name}#{changes(existing.data, data)}"
         }}
    end
  end

  defp ensure_free_ids(client, existing, actual) do
    others = Enum.reject(actual, &(existing && &1.name == existing.name))

    conflicts =
      for id <- client.ids,
          other <- others,
          MapSet.member?(other.managed_ids, id),
          do: "#{id} (#{other.name})"

    if conflicts == [],
      do: :ok,
      else:
        {:skip,
         "#{client.name}: already used by other AdGuard clients: #{Enum.join(conflicts, ", ")}"}
  end

  defp tags(client, current_tags, supported_tags) do
    kept = Enum.reject(current_tags, &String.starts_with?(&1, @device_tag_prefix))
    device_tag = Map.get(@device_tag_by_kind, client.kind, @default_device_tag)
    belgo_tags = Enum.filter(client.tags, &MapSet.member?(supported_tags, &1))

    [device_tag | kept ++ belgo_tags]
    |> Enum.filter(&(MapSet.size(supported_tags) == 0 or MapSet.member?(supported_tags, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp comparable(data) do
    {data["name"], comparable_field(data, "ids"), comparable_field(data, "tags")}
  end

  defp list_of(data, field), do: List.wrap(Map.get(data, field))

  defp comparable_id(id) do
    case managed_id(id) do
      [normalized] -> [normalized]
      [] -> [id]
    end
  end

  defp changes(before, after_change) do
    changed =
      for field <- ["name", "ids", "tags"],
          comparable_field(before, field) != comparable_field(after_change, field) do
        "#{field}: #{format_field(before[field])} → #{format_field(after_change[field])}"
      end

    if changed == [], do: "", else: " (" <> Enum.join(changed, "; ") <> ")"
  end

  defp comparable_field(data, "ids") do
    data
    |> list_of("ids")
    |> Enum.flat_map(&comparable_id/1)
    |> Enum.sort()
  end

  defp comparable_field(data, "tags"), do: Enum.sort(list_of(data, "tags"))

  defp comparable_field(data, field), do: data[field]

  defp format_field(values) when is_list(values), do: "[" <> Enum.join(values, ", ") <> "]"
  defp format_field(value), do: to_string(value)

  defp managed_id(id) do
    case {MacAddress.normalize(id), IpAddress.parse(id)} do
      {{:ok, mac}, _ip} -> [mac]
      {:error, {:ok, address}} -> [IpAddress.format(address)]
      {:error, :error} -> []
    end
  end

  defp same_name?(left_name, right_name) when is_binary(left_name) and is_binary(right_name),
    do: String.downcase(left_name) == String.downcase(right_name)

  defp same_name?(_left_name, _right_name), do: false
end
