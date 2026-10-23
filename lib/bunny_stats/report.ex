defmodule BunnyStats.Report do
  @moduledoc "Renders a self-contained HTML report. All API strings are escaped."
  @template Path.expand("../../priv/report.html.eex", __DIR__)
  @external_resource @template

  def render(report), do: EEx.eval_file(@template, [r: report], trim: true)

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

  def chart(days, metric, label) do
    max_value = days |> Enum.map(&(Map.get(&1, metric) || 0)) |> Enum.max(fn -> 0 end)
    scale = if max_value > 0, do: max_value, else: 1

    bars =
      Enum.with_index(days)
      |> Enum.map_join(fn {day, i} ->
        value = Map.get(day, metric)
        height = if is_number(value), do: max(value / scale * 74, 2), else: 2

        color =
          cond do
            is_nil(value) -> "#444"
            day.partial -> "#436c83"
            true -> "#92c9f4"
          end

        title = chart_value(day, metric)
        tab = if i == length(days) - 1, do: 0, else: -1

        """
        <g class="point" tabindex="#{tab}" role="img" aria-label="#{escape(title)}" data-value="#{escape(title)}">
          <title>#{escape(title)}</title>
          <rect x="#{i * 20 + 3}" y="#{78 - height}" width="14" height="#{height}" fill="#{color}"/>
          <rect class="hit" x="#{i * 20}" y="0" width="20" height="82" fill="transparent"/>
        </g>
        """
      end)

    last = List.last(days)
    first = List.first(days)
    readout = if last, do: chart_value(last, metric), else: "Keine Messwerte"

    """
    <div class="metric-chart">
      <h3>#{escape(label)}</h3>
      <div class="chart-readout">#{escape(readout)}</div>
      <svg viewBox="0 0 #{max(length(days) * 20, 20)} 84" preserveAspectRatio="none" role="group" aria-label="#{escape(label)}: letzte 30 Tage. Pfeiltasten wählen einen Tag.">#{bars}</svg>
      <div class="chart-axis"><span>#{if first, do: escape(first.date)}</span><span>#{if last, do: escape(last.date)}</span></div>
    </div>
    """
  end

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
    "<!doctype html><html lang=\"de\"><meta charset=\"utf-8\"><title>Bunny Stats: Abruf fehlgeschlagen</title><style>body{background:#000;color:#fff;font:16px system-ui;margin:4rem;max-width:60rem}h1{font-size:24px}</style><h1>Bunny Stats: Abruf fehlgeschlagen</h1><p>#{escape(message)}</p><p>Keine aktuellen Kosten verfügbar. Es wurden keine Bunny-Ressourcen verändert.</p></html>"
  end
end
