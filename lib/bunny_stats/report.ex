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

  def traffic_chart(days) do
    max_value = days |> Enum.map(&(&1.traffic || 0)) |> Enum.max(fn -> 0 end) |> max(1)

    bars =
      Enum.with_index(days)
      |> Enum.map_join(fn {day, i} ->
        height = if day.traffic, do: max(day.traffic / max_value * 76, 0), else: 0
        color = if day.partial, do: "#436c83", else: "#92c9f4"

        title =
          "#{day.date}: #{gb(day.traffic)} GB" <>
            if(day.partial, do: " (laufender Tag)", else: "")

        "<rect x=\"#{i * 20 + 2}\" y=\"#{80 - height}\" width=\"14\" height=\"#{height}\" fill=\"#{color}\"><title>#{escape(title)}</title></rect>"
      end)

    "<svg viewBox=\"0 0 #{max(length(days) * 20, 20)} 84\" role=\"img\" aria-label=\"Täglicher Traffic in GB. Werte in der folgenden Tabelle.\">#{bars}</svg>"
  end

  def error(message) do
    "<!doctype html><html lang=\"de\"><meta charset=\"utf-8\"><title>Bunny Stats: Abruf fehlgeschlagen</title><style>body{background:#000;color:#fff;font:16px system-ui;margin:4rem;max-width:60rem}h1{font-size:24px}</style><h1>Bunny Stats: Abruf fehlgeschlagen</h1><p>#{escape(message)}</p><p>Keine aktuellen Kosten verfügbar. Es wurden keine Bunny-Ressourcen verändert.</p></html>"
  end
end
