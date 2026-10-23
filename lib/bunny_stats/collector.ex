defmodule BunnyStats.Collector do
  @moduledoc "Collects a current-month snapshot without application configuration or secrets."
  alias BunnyStats.API

  @charts ~w(cpuUsageChart ramUsageChart trafficChart instancesChart volumesUsageChart volumesCapacityChart volumesSplitUsageChart volumesSplitCapacityChart)

  def collect(profile \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    first = Date.beginning_of_month(DateTime.to_date(now))

    query =
      URI.encode_query(%{
        fromDate: "#{first}T00:00:00Z",
        toDate: DateTime.to_iso8601(now),
        granularity: "Daily"
      })

    with {:ok, apps} <- list_apps(profile), {:ok, billing} <- API.get("/billing", profile) do
      results =
        apps
        |> Task.async_stream(&app(&1, query, profile), max_concurrency: 4, timeout: :infinity)
        |> Enum.map(fn {:ok, a} -> a end)

      {cdn, cdn_errors} = optional("/billing/summary", profile, [])

      {:ok,
       %{
         "fetchedAt" => DateTime.to_iso8601(DateTime.utc_now() |> DateTime.truncate(:second)),
         "statisticsThrough" => DateTime.to_iso8601(now),
         "month" => String.slice(Date.to_iso8601(first), 0, 7),
         "billing" => sanitize_billing(billing),
         "apps" => results,
         "cdn" => Enum.map(cdn, &Map.take(&1, ~w(PullZoneId MonthlyUsage MonthlyBandwidthUsed))),
         "errors" => cdn_errors
       }}
    end
  end

  def sanitize_billing(billing) do
    billing
    |> Enum.filter(fn {k, _} ->
      k == "ThisMonthCharges" or String.starts_with?(k, ["MonthlyCharges", "MonthlyMc"])
    end)
    |> Map.new(fn {k, v} ->
      {k, if(is_map(v), do: Map.take(v, ~w(Usage TotalUnits MeasuringUnit)), else: v)}
    end)
  end

  defp list_apps(profile, cursor \\ nil, seen \\ MapSet.new(), items \\ []) do
    query =
      URI.encode_query(if cursor, do: %{limit: 1000, nextCursor: cursor}, else: %{limit: 1000})

    with {:ok, page} <- API.get("/mc/apps?" <> query, profile) do
      next = page["cursor"]
      collected = items ++ Map.fetch!(page, "items")

      cond do
        next in [nil, ""] -> {:ok, collected}
        MapSet.member?(seen, next) -> {:error, "Bunny liefert einen wiederholten Seiten-Cursor"}
        true -> list_apps(profile, next, MapSet.put(seen, next), collected)
      end
    end
  end

  defp app(app, query, profile) do
    base = "/mc/apps/" <> URI.encode(app["id"], &URI.char_unreserved?/1)
    {overview, e1} = optional(base <> "/overview", profile, %{})
    {statistics, e2} = optional(base <> "/statistics?" <> query, profile, %{})
    {volumes, e3} = optional(base <> "/volumes", profile, %{})

    Map.merge(Map.take(app, ~w(id name status)), %{
      "monthlyCost" => overview["monthlyCost"],
      "statistics" => Map.take(statistics, @charts),
      "volumes" => %{"items" => Enum.map(Map.get(volumes, "items", []), &sanitize_volume/1)},
      "errors" => e1 ++ e2 ++ e3
    })
  end

  defp sanitize_volume(v) do
    Map.take(v, ~w(id name size totalUsage totalInstancesCount attachedInstancesCount))
    |> Map.put(
      "volumeInstances",
      Enum.map(Map.get(v, "volumeInstances", []), &Map.take(&1, ~w(id region status size usage)))
    )
  end

  defp optional(path, profile, fallback) do
    case API.get(path, profile) do
      {:ok, value} -> {value, []}
      {:error, error} -> {fallback, [path <> ": " <> error]}
    end
  end
end
