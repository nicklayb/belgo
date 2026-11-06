defmodule Belgo.Providers.Options do
  @moduledoc "Validation helpers shared by the providers' `parse_config/2`."

  @doc """
  Builds a configuration struct from `{field, {:ok, value} | {:error, message}}`
  results, collecting every error message. The `:options` field only validates.
  """
  @spec build(module(), [{atom(), {:ok, any()} | {:error, String.t()}}]) ::
          {:ok, struct()} | {:error, [String.t()]}
  def build(module, results) do
    case for({_field, {:error, message}} <- results, do: message) do
      [] ->
        {:ok,
         struct!(
           module,
           for({field, {:ok, value}} <- results, field != :options, do: {field, value})
         )}

      messages ->
        {:error, messages}
    end
  end

  @doc "Rejects option names outside of `allowed`."
  @spec validate_names(map(), [String.t()]) :: {:ok, nil} | {:error, String.t()}
  def validate_names(options, allowed) do
    unknown_names =
      options
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed))
      |> Enum.sort()

    case unknown_names do
      [] ->
        {:ok, nil}

      unknown ->
        {:error,
         "unknown options: #{Enum.join(unknown, ", ")} (expected #{Enum.join(allowed, ", ")})"}
    end
  end

  @doc "Validates an http(s) URL, without trailing slash."
  @spec url(any()) :: {:ok, String.t()} | {:error, String.t()}
  def url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, String.trim_trailing(value, "/")}

      _invalid ->
        {:error, "url must be an http(s) URL"}
    end
  end

  def url(_value), do: {:error, "url is required"}

  @doc "Validates a boolean option."
  @spec boolean(any(), String.t()) :: {:ok, boolean()} | {:error, String.t()}
  def boolean(value, _name) when is_boolean(value), do: {:ok, value}
  def boolean(_value, name), do: {:error, "#{name} must be true or false"}
end
