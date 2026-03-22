defmodule Notiert.Director.Enrichment do
  @moduledoc """
  Async enrichment lookups. Resolves visitor IP to company/location via ipinfo.io,
  and reverse geocodes granted geolocation via Nominatim (OpenStreetMap).

  All calls are async — results are sent back to the Session process as events.
  Free tiers, no API keys required.
  """

  require Logger

  @ipinfo_url "https://ipinfo.io"
  @nominatim_url "https://nominatim.openstreetmap.org/reverse"
  @request_timeout 10_000
  @connect_timeout 5_000

  @doc """
  Look up IP address via ipinfo.io. Returns company, city, region, country, coordinates.
  Sends {:enrichment_result, :ip_lookup, result} back to caller.
  """
  def lookup_ip(ip_string, reply_to) do
    Task.start(fn ->
      result = do_ip_lookup(ip_string)
      send(reply_to, {:enrichment_result, :ip_lookup, result})
    end)
  end

  @doc """
  Reverse geocode lat/lng via Nominatim. Returns place name, road, city, etc.
  Sends {:enrichment_result, :reverse_geocode, result} back to caller.
  """
  def reverse_geocode(lat, lng, reply_to) do
    Task.start(fn ->
      result = do_reverse_geocode(lat, lng)
      send(reply_to, {:enrichment_result, :reverse_geocode, result})
    end)
  end

  # --- IP Lookup via ipinfo.io ---

  defp do_ip_lookup(ip_string) do
    url = ~c"#{@ipinfo_url}/#{ip_string}/json"

    Logger.info("[enrichment] Looking up IP: #{ip_string}")

    case :httpc.request(
           :get,
           {url, [{~c"accept", ~c"application/json"}, {~c"user-agent", ~c"notiert/1.0"}]},
           [timeout: @request_timeout, connect_timeout: @connect_timeout, ssl: ssl_opts()],
           []
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, data} ->
            result = %{
              ip: data["ip"],
              city: data["city"],
              region: data["region"],
              country: data["country"],
              org: data["org"],
              hostname: data["hostname"],
              loc: data["loc"],
              timezone: data["timezone"],
              postal: data["postal"]
            }

            Logger.info("[enrichment] IP resolved: #{result.city}, #{result.country} — org: #{result.org}")
            {:ok, result}

          {:error, reason} ->
            Logger.warning("[enrichment] Failed to parse ipinfo response: #{inspect(reason)}")
            {:error, :parse_failed}
        end

      {:ok, {{_, 429, _}, _, _}} ->
        Logger.warning("[enrichment] ipinfo.io rate limited")
        {:error, :rate_limited}

      {:ok, {{_, status, _}, _, _}} ->
        Logger.warning("[enrichment] ipinfo.io returned #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[enrichment] ipinfo.io request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Reverse Geocode via Nominatim ---

  defp do_reverse_geocode(lat, lng) do
    url = ~c"#{@nominatim_url}?lat=#{lat}&lon=#{lng}&format=json&zoom=18&addressdetails=1"

    Logger.info("[enrichment] Reverse geocoding: #{lat}, #{lng}")

    case :httpc.request(
           :get,
           {url, [{~c"accept", ~c"application/json"}, {~c"user-agent", ~c"notiert/1.0 (henrystoll.de)"}]},
           [timeout: @request_timeout, connect_timeout: @connect_timeout, ssl: ssl_opts()],
           []
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, data} ->
            address = data["address"] || %{}

            result = %{
              display_name: data["display_name"],
              place: address["building"] || address["amenity"] || address["office"] || address["shop"],
              road: address["road"],
              neighbourhood: address["neighbourhood"] || address["suburb"],
              city: address["city"] || address["town"] || address["village"],
              state: address["state"],
              country: address["country"],
              country_code: address["country_code"],
              postcode: address["postcode"]
            }

            place_desc = result.place || result.road || result.neighbourhood || result.city
            Logger.info("[enrichment] Location resolved: #{place_desc}, #{result.city}, #{result.country}")
            {:ok, result}

          {:error, reason} ->
            Logger.warning("[enrichment] Failed to parse Nominatim response: #{inspect(reason)}")
            {:error, :parse_failed}
        end

      {:ok, {{_, status, _}, _, _}} ->
        Logger.warning("[enrichment] Nominatim returned #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[enrichment] Nominatim request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
