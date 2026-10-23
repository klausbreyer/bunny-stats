defmodule BunnyStats.Analysis do
  @moduledoc "Keeps billing totals, telemetry and estimates separate, preserving reconciliation gaps."
  @traffic ~w(MonthlyChargesEUTraffic MonthlyChargesUSTraffic MonthlyChargesASIATraffic MonthlyChargesAFTraffic MonthlyChargesSATraffic)
  @nested ~w(MonthlyChargesScriptingRequests MonthlyChargesScriptingCpu)
  @components [
    {"CPU", "MonthlyMcCpu"},
    {"Memory", "MonthlyMcMemory"},
    {"Egress", "MonthlyMcEgressTraffic"},
    {"Volumes", "MonthlyMcVolumes"},
    {"Anycast IP", "MonthlyMcIp"},
    {"Ingress", "MonthlyMcIngressTraffic"}
  ]

  def build(snapshot, reference \\ nil) do
    billing = snapshot["billing"]
    month = snapshot["month"] || String.slice(snapshot["fetchedAt"], 0, 7)
    through = snapshot["statisticsThrough"] || snapshot["fetchedAt"]

    apps =
      Enum.map(snapshot["apps"], &analyze_app(&1, month, through))
      |> Enum.sort_by(&(&1["monthlyCost"] || -1), :desc)

    components =
      Enum.map(@components, fn {name, key} ->
        item = billing[key]

        %{
          name: name,
          cost: if(item, do: item["Usage"]),
          units: if(item, do: item["TotalUnits"]),
          unit: if(item, do: item["MeasuringUnit"])
        }
      end)

    products = products(billing)
    app_sum = apps |> Enum.map(& &1["monthlyCost"]) |> complete_sum()
    component_sum = components |> Enum.map(& &1.cost) |> sum_present()
    product_sum = products |> Enum.map(& &1.cost) |> sum_present()
    mc = billing["MonthlyChargesMagicContainers"]
    cdn_sum = snapshot |> Map.get("cdn", []) |> Enum.map(& &1["MonthlyUsage"]) |> sum_present()
    volumes = Enum.flat_map(apps, & &1["volumeRows"])

    %{
      snapshot: snapshot,
      month: month,
      through: through,
      apps: apps,
      components: components,
      products: products,
      volumes: volumes,
      checks: [
        check("Produkte gegen Account gesamt", product_sum, billing["ThisMonthCharges"]),
        check("MC-Einzelposten gegen MC-Abrechnung", component_sum, mc),
        check("Vorhandene Apps gegen MC-Abrechnung", app_sum, mc),
        check("Vorhandene Apps gegen MC-Einzelposten", app_sum, component_sum),
        check("Pull Zones gegen CDN-Abrechnung", cdn_sum, sum_fields(billing, @traffic))
      ],
      reference: compare_reference(billing, reference, month),
      component_sum: component_sum,
      app_sum: app_sum,
      errors: Map.get(snapshot, "errors", []) ++ Enum.flat_map(apps, &Map.get(&1, "errors", []))
    }
  end

  def products(billing) do
    rest =
      billing
      |> Enum.filter(fn {k, v} ->
        String.starts_with?(k, "MonthlyCharges") and k not in (@traffic ++ @nested) and
          is_number(v) and v != 0
      end)
      |> Enum.map(fn {k, v} -> %{name: product_name(k), cost: v} end)

    [%{name: "CDN", cost: sum_fields(billing, @traffic)} | rest] |> Enum.sort_by(& &1.cost, :desc)
  end

  def check(label, observed, expected) do
    delta = if is_number(observed) and is_number(expected), do: observed - expected

    %{
      label: label,
      observed: observed,
      expected: expected,
      delta: delta,
      status:
        cond do
          is_nil(delta) -> :missing
          abs(delta) <= 0.005 -> :ok
          true -> :mismatch
        end
    }
  end

  def compare_reference(_, nil, _), do: []

  def compare_reference(billing, reference, month) do
    if reference["month"] == month do
      Enum.map(reference["values"], fn {key, expected} ->
        value = if key == "CDN", do: sum_fields(billing, @traffic), else: get_value(billing, key)
        result = check(reference["labels"][key] || key, value, expected)
        # A screenshot only contains rounded cents. Compare at its precision.
        Map.put(
          result,
          :status,
          if(is_number(value) and Float.round(value / 1, 2) == expected, do: :ok, else: :mismatch)
        )
      end)
    else
      []
    end
  end

  defp get_value(billing, "MonthlyMc" <> _ = key), do: get_in(billing, [key, "Usage"])
  defp get_value(billing, key), do: billing[key]

  defp analyze_app(app, month, through) do
    stats = app["statistics"] || %{}
    {:ok, until, _} = DateTime.from_iso8601(through)
    first = Date.from_iso8601!(month <> "-01")
    last = min_date(Date.end_of_month(first), DateTime.to_date(until))

    days =
      if Date.compare(first, last) == :gt,
        do: [],
        else: Enum.map(Date.range(first, last), &day(stats, &1, until))

    app
    |> Map.put("days", days)
    |> Map.put("trafficGb", sum_chart(stats["trafficChart"], first, last))
    |> Map.put("volumeRows", volume_rows(app, stats, first, until))
  end

  defp day(stats, date, until) do
    key = "#{date}T00:00:00Z"

    %{
      date: Date.to_iso8601(date),
      partial: Date.compare(date, DateTime.to_date(until)) == :eq,
      cpu: get_in(stats, ["cpuUsageChart", key]),
      ram: get_in(stats, ["ramUsageChart", key]),
      traffic: get_in(stats, ["trafficChart", key]),
      capacity: get_in(stats, ["volumesCapacityChart", key]),
      used: get_in(stats, ["volumesUsageChart", key]),
      instances: get_in(stats, ["instancesChart", key])
    }
  end

  defp volume_rows(app, stats, first, until) do
    current = get_in(app, ["volumes", "items"]) || []
    capacity = stats["volumesSplitCapacityChart"] || %{}
    ids = Enum.uniq(Enum.map(current, & &1["id"]) ++ Map.keys(capacity))

    Enum.map(ids, fn id ->
      v = Enum.find(current, &(&1["id"] == id))
      instances = if(v, do: Map.get(v, "volumeInstances", []), else: [])
      gb = if(v, do: Enum.map(instances, & &1["size"]) |> sum_present())

      %{
        id: id,
        app: app["name"],
        name: if(v, do: v["name"], else: "Historisches Volume"),
        size: gb,
        used: if(v, do: v["totalUsage"]),
        detached:
          v != nil and instances != [] and Enum.all?(instances, &(&1["status"] == "detached")),
        historical: v == nil,
        cost: volume_estimate(capacity[id], first, until),
        run_rate: if(gb, do: gb * 0.10),
        regions: instances |> Enum.map(& &1["region"]) |> Enum.uniq() |> Enum.join(", ")
      }
    end)
  end

  @doc "Rough capacity-time estimate; daily averages cannot establish exact creation/deletion time."
  def volume_estimate(nil, _, _), do: nil

  def volume_estimate(chart, first, until) do
    chart
    |> Enum.flat_map(fn {timestamp, bytes} ->
      with {:ok, start, _} <- DateTime.from_iso8601(timestamp),
           true <- String.starts_with?(timestamp, String.slice(Date.to_iso8601(first), 0, 7)),
           true <- is_number(bytes),
           true <- DateTime.compare(start, until) == :lt do
        seconds = min(DateTime.diff(until, start), 86_400)
        [bytes / 1.0e9 * seconds / 86_400 / Date.days_in_month(first) * 0.10]
      else
        _ -> []
      end
    end)
    |> sum_present()
  end

  defp sum_chart(nil, _, _), do: nil

  defp sum_chart(chart, first, last) do
    chart
    |> Enum.filter(fn {k, _} ->
      d = String.slice(k, 0, 10)
      d >= Date.to_iso8601(first) and d <= Date.to_iso8601(last)
    end)
    |> Enum.map(fn {_, v} -> v end)
    |> sum_present()
    |> then(fn n -> if(n, do: n / 1.0e9) end)
  end

  def sum_present(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> nil
      numbers -> Enum.sum(numbers)
    end
  end

  defp complete_sum(values) do
    if Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil
  end

  defp sum_fields(map, keys), do: keys |> Enum.map(&map[&1]) |> sum_present()
  defp min_date(a, b), do: if(Date.compare(a, b) == :gt, do: b, else: a)
  defp product_name("MonthlyChargesMagicContainers"), do: "Magic Containers"
  defp product_name("MonthlyCharges" <> name), do: name
end
