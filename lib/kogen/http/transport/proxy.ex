defmodule Kogen.Http.Transport.Proxy do
  @moduledoc false

  @proxy_variables ~w(https_proxy HTTPS_PROXY all_proxy ALL_PROXY http_proxy HTTP_PROXY)
  @no_proxy_variables ~w(no_proxy NO_PROXY)
  @profile_name :kogen_chatgpt_proxy

  @type profile :: pid()
  @type reason :: :transport | :invalid_proxy | :proxy_auth_unsupported

  @spec with_profile(String.t(), map(), (profile() | nil -> result)) ::
          result | {:error, reason()}
        when result: term()
  def with_profile(url, proxy_env, fun)
      when is_binary(url) and is_map(proxy_env) and is_function(fun, 1) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        proxy_env
        |> then(&proxy_for(host, &1))
        |> with_profile_lock(fun)

      _http_url ->
        fun.(nil)
    end
  end

  defp with_profile_lock({:ok, proxy}, fun) do
    :global.trans({{__MODULE__, @profile_name}, self()}, fn ->
      with {:ok, profile} <- start_profile(proxy) do
        try do
          fun.(profile)
        after
          :gen_server.stop(profile)
        end
      end
    end)
  end

  defp with_profile_lock({:error, reason}, _fun), do: {:error, reason}

  defp proxy_for(host, proxy_env) do
    if bypass_proxy?(host, proxy_env) do
      {:ok, nil}
    else
      case env_value(proxy_env, @proxy_variables) do
        nil -> {:ok, nil}
        value -> parse_proxy(value)
      end
    end
  end

  defp parse_proxy(value) do
    case URI.parse(value) do
      %URI{scheme: "http", host: host, port: port, userinfo: nil, path: path, query: nil}
      when is_binary(host) and is_integer(port) and port in 1..65_535 and path in [nil, "", "/"] ->
        {:ok, {String.to_charlist(host), port}}

      %URI{userinfo: userinfo} when is_binary(userinfo) ->
        {:error, :proxy_auth_unsupported}

      _invalid ->
        {:error, :invalid_proxy}
    end
  end

  defp start_profile(proxy) do
    case :inets.start(:httpc, [{:profile, @profile_name}], :stand_alone) do
      {:ok, profile} ->
        if proxy do
          case :httpc.set_options([https_proxy: {proxy, []}], profile) do
            :ok ->
              {:ok, profile}

            {:error, _reason} ->
              :gen_server.stop(profile)
              {:error, :transport}
          end
        else
          {:ok, profile}
        end

      {:error, _reason} ->
        {:error, :transport}
    end
  end

  defp bypass_proxy?(host, proxy_env) do
    host = normalize_host(host)

    case env_value(proxy_env, @no_proxy_variables) do
      nil ->
        false

      entries ->
        entries
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.any?(&matches_host?(host, &1))
    end
  end

  defp matches_host?(_host, "*"), do: true
  defp matches_host?(_host, ""), do: false

  defp matches_host?(host, <<".", suffix::binary>>) do
    suffix = normalize_host(suffix)
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp matches_host?(host, entry), do: host == normalize_host(entry)

  defp normalize_host(host), do: host |> String.trim_trailing(".") |> String.downcase()

  defp env_value(env, names) do
    Enum.find_value(names, fn name ->
      case Map.get(env, name) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            value -> value
          end

        _unset ->
          nil
      end
    end)
  end
end
