defmodule BunnyStats.Report do
  @moduledoc "Renders a self-contained HTML report. All API strings are escaped."
  @template Path.expand("../../priv/report.html.eex", __DIR__)
  @app_template Path.expand("../../priv/app.html.eex", __DIR__)
  @css Path.expand("../../priv/style.css", __DIR__)
  @external_resource @template
  @external_resource @app_template
  @external_resource @css

  # Fixed categorical order for product tiles and the product segment bar.
  @product_colors ~w(#2a78d6 #1baf7a #eda100 #e87ba4 #6250d6 #eb6834 #008300 #e34948)
  # One color per entity, shared by billing components, cost drivers and charts.
  @entity_colors %{cpu: "#eb6834", ram: "#6250d6", traffic: "#2a78d6", capacity: "#1baf7a"}
  @metrics [{:traffic, "Traffic"}, {:ram, "RAM"}, {:cpu, "CPU"}, {:capacity, "Volumes"}]

  @doc "Overview page. `pages` is the relative directory holding the app detail pages."
  def render(report, pages), do: EEx.eval_file(@template, [r: report, pages: pages], trim: true)

  @doc "Detail page for one app. `nav` holds the relative overview path and the previous/next app in ranking order."
  def render_app(report, app, nav),
    do: EEx.eval_file(@app_template, [r: report, app: app, nav: nav], trim: true)

  def css, do: File.read!(@css)

  @doc "Safe file name for an app page, derived from the API id."
  def page_file(%{"id" => id}), do: page_file(id)
  def page_file(id), do: String.replace(to_string(id), ~r/[^A-Za-z0-9_-]/, "_") <> ".html"

  def metrics, do: @metrics
  def product_colors, do: @product_colors
  def color(metric) when is_atom(metric), do: @entity_colors[metric]
  def color("CPU"), do: color(:cpu)
  def color("Memory"), do: color(:ram)
  def color("RAM"), do: color(:ram)
  def color("Egress"), do: color(:traffic)
  def color("Traffic"), do: color(:traffic)
  def color("Volumes"), do: color(:capacity)
  def color(_), do: "#eda100"

  def escape(nil), do: ""

  def escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def number(nil, _), do: "k. A."

  def number(value, digits),
    do: :erlang.float_to_binary(value / 1, decimals: digits) |> String.replace(".", ",")

  def money(value, digits \\ 2)
  def money(nil, _), do: "k. A."
  def money(value, digits), do: number(value, digits) <> " $"
  def gb(nil), do: "k. A."
  def gb(bytes), do: number(bytes / 1.0e9, 3)
  def share(_, nil), do: "k. A."
  def share(_, 0), do: "k. A."
  def share(nil, _), do: "k. A."
  def share(value, total), do: number(value / total * 100, 1) <> " %"
  def status(:ok), do: "Stimmt"
  def status(:mismatch), do: "Abweichung"
  def status(:missing), do: "Unvollständig"
  def app_status("active"), do: "aktiv"
  def app_status("inactive"), do: "inaktiv"
  def app_status(other), do: escape(other)
  def unit(%{units: nil}), do: "Keine Angabe"
  def unit(%{units: n, unit: "Bytes"}), do: gb(n) <> " GB"
  def unit(%{units: n, unit: "Seconds"}), do: number(n, 0) <> " CPU-Sekunden"
  def unit(%{units: n, unit: "Block-seconds"}), do: number(n, 0) <> " Block-Sekunden"
  def unit(%{units: n, unit: u}), do: number(n, 0) <> " " <> escape(u)

  def status_chip(app_status) do
    ~s|<span class="chip #{if app_status == "active", do: "on", else: "off"}"><i></i>#{app_status(app_status)}</span>|
  end

  def check_chip(:ok), do: ~s|<span class="chip ok">✓ Stimmt</span>|
  def check_chip(:mismatch), do: ~s|<span class="chip warn">△ Abweichung</span>|
  def check_chip(:missing), do: ~s|<span class="chip warn">◌ Unvollständig</span>|

  @doc "Area chart over 30 days with per-day hover, keyboard navigation and a readout."
  def chart(days, metric, label, id) do
    n = max(length(days), 1)
    width = n * 20
    color = color(metric)

    max_value =
      days |> Enum.map(&Map.get(&1, metric)) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

    scale = if max_value > 0, do: max_value, else: 1

    points =
      Enum.with_index(days, fn day, i ->
        value = Map.get(day, metric)
        {i * 20 + 10, if(is_number(value), do: 84 - value / scale * 70), day}
      end)

    line = Enum.map_join(runs(points), " ", &path/1)
    area = Enum.map_join(runs(points), " ", &closed_path/1)

    missing =
      for {x, nil, _} <- points,
          into: "",
          do: ~s|<rect x="#{x - 4}" y="82" width="8" height="2" rx="1" class="miss"/>|

    hits =
      Enum.map_join(Enum.with_index(points), fn {{x, y, day}, i} ->
        title = chart_value(day, metric)
        tab = if i == n - 1, do: 0, else: -1

        dot =
          if y,
            do: ~s|<circle class="dot" cx="#{x}" cy="#{f(y)}" r="4.5" fill="#{color}"/>|,
            else: ""

        ~s|<g class="point" tabindex="#{tab}" role="img" aria-label="#{escape(title)}" data-value="#{escape(title)}"><title>#{escape(title)}</title><rect class="hit" x="#{i * 20}" y="0" width="20" height="100" fill="transparent"/><line class="cursor" x1="#{x}" x2="#{x}" y1="6" y2="84"/>#{dot}</g>|
      end)

    first = List.first(days)
    last = List.last(days)
    readout = if last, do: chart_value(last, metric), else: "Keine Messwerte"

    peak =
      if max_value > 0, do: "Spitze " <> short_value(max_value, metric), else: "keine Nutzung"

    """
    <div class="metric-chart" style="--c:#{color}">
      <div class="metric-head"><h4>#{escape(label)}</h4><span class="peak">#{escape(peak)}</span></div>
      <div class="chart-readout">#{escape(readout)}</div>
      <svg viewBox="0 0 #{width} 100" preserveAspectRatio="none" role="group" aria-label="#{escape(label)}: letzte 30 Tage. Pfeiltasten wählen einen Tag.">
        <defs><linearGradient id="#{escape(id)}" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#{color}" stop-opacity=".28"/><stop offset="1" stop-color="#{color}" stop-opacity="0"/></linearGradient></defs>
        <line x1="0" x2="#{width}" y1="84" y2="84" class="base"/>
        <path d="#{area}" fill="url(##{escape(id)})"/>
        <path d="#{line}" fill="none" stroke="#{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>
        #{missing}#{hits}
      </svg>
      <div class="chart-axis"><span>#{if first, do: escape(first.date)}</span><span>#{if last, do: escape(last.date)}</span></div>
    </div>
    """
  end

  @doc "Compact single-series line for ranking rows. Missing days break the line."
  def sparkline(days, metric) do
    n = max(length(days), 1)

    max_value =
      days |> Enum.map(&Map.get(&1, metric)) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

    scale = if max_value > 0, do: max_value, else: 1

    points =
      Enum.with_index(days, fn day, i ->
        value = Map.get(day, metric)
        {i * 4 + 2, if(is_number(value), do: 26 - value / scale * 22), day}
      end)

    ~s|<svg class="spark" viewBox="0 0 #{n * 4} 28" preserveAspectRatio="none" aria-hidden="true"><path d="#{Enum.map_join(runs(points), " ", &path/1)}" fill="none" stroke="#{color(metric)}" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>|
  end

  @doc "Donut from {name, value, color} segments with a 2px surface gap. Nil values are skipped."
  def donut(segments, center, caption) do
    present =
      for {name, value, color} <- segments,
          is_number(value) and value > 0,
          do: {name, value, color}

    total = present |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    circumference = 2 * :math.pi() * 42

    {arcs, _} =
      Enum.map_reduce(present, 0, fn {name, value, color}, offset ->
        length = value / total * circumference
        gap = min(2.5, length / 2)
        dash = length - gap

        arc =
          ~s|<circle r="42" cx="60" cy="60" fill="none" stroke="#{color}" stroke-width="14" stroke-dasharray="#{f(dash)} #{f(circumference - dash)}" stroke-dashoffset="#{f(-offset - gap / 2)}"><title>#{escape(name)}</title></circle>|

        {arc, offset + length}
      end)

    "<svg class=\"donut\" viewBox=\"0 0 120 120\" role=\"img\" aria-label=\"#{escape(caption)}\"><g transform=\"rotate(-90 60 60)\">#{Enum.join(arcs)}</g><text x=\"60\" y=\"58\" text-anchor=\"middle\" class=\"donut-value\">#{escape(center)}</text><text x=\"60\" y=\"74\" text-anchor=\"middle\" class=\"donut-caption\">#{escape(caption)}</text></svg>"
  end

  @doc "Proportional segment bar from {name, value, color} segments."
  def segbar(segments) do
    inner =
      for {name, value, color} <- segments, is_number(value) and value > 0, into: "" do
        ~s|<i style="flex:#{f(value * 1000)};background:#{color}" title="#{escape(name)}"></i>|
      end

    ~s|<div class="segbar" aria-hidden="true">#{inner}</div>|
  end

  # Splits points into runs of consecutive measured days; nil breaks the line.
  defp runs(points) do
    points
    |> Enum.chunk_by(fn {_, y, _} -> is_nil(y) end)
    |> Enum.reject(fn [{_, y, _} | _] -> is_nil(y) end)
  end

  defp path(run) do
    Enum.map_join(Enum.with_index(run), " ", fn {{x, y, _}, j} ->
      "#{if j == 0, do: "M", else: "L"}#{x} #{f(y)}"
    end)
  end

  defp closed_path(run) do
    {x0, _, _} = hd(run)
    {xn, _, _} = List.last(run)
    "M#{x0} 84 " <> Enum.map_join(run, " ", fn {x, y, _} -> "L#{x} #{f(y)}" end) <> " L#{xn} 84 Z"
  end

  defp f(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp f(value), do: to_string(value)

  defp short_value(value, :cpu), do: number(value, 3)
  defp short_value(value, _), do: gb(value) <> " GB"

  defp chart_value(day, metric) do
    value = Map.get(day, metric)

    formatted =
      cond do
        is_nil(value) -> "keine Messwerte"
        metric == :cpu -> number(value, 5) <> " API-Wert"
        true -> gb(value) <> " GB"
      end

    extra = if metric == :capacity, do: " bereit · " <> gb(day.used) <> " GB belegt", else: ""

    day.date <>
      " · " <> formatted <> extra <> if(day.partial, do: " · heute, unvollständig", else: "")
  end

  def driver_width(nil, _), do: 0
  def driver_width(_, 0), do: 0
  def driver_width(cost, maximum), do: cost / maximum * 100

  def error(message) do
    "<!doctype html><html lang=\"de\"><meta charset=\"utf-8\"><title>Bunny Stats: Abruf fehlgeschlagen</title><style>body{background:#f4f5fa;color:#101828;font:16px -apple-system,system-ui,sans-serif;margin:4rem;max-width:60rem}h1{font-size:24px}</style><h1>Bunny Stats: Abruf fehlgeschlagen</h1><p>#{escape(message)}</p><p>Keine aktuellen Kosten verfügbar. Es wurden keine Bunny-Ressourcen verändert.</p></html>"
  end
end
