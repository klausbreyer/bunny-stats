defmodule BunnyStats.AnalysisTest do
  use ExUnit.Case, async: true
  alias BunnyStats.{Analysis, Collector, Report}

  test "preserves mismatches between billed totals and components" do
    billing = %{
      "ThisMonthCharges" => 12.34,
      "MonthlyChargesMagicContainers" => 10.0,
      "MonthlyMcCpu" => %{"Usage" => 2.0},
      "MonthlyMcMemory" => %{"Usage" => 4.0},
      "MonthlyMcEgressTraffic" => %{"Usage" => 3.0},
      "MonthlyMcVolumes" => %{"Usage" => 2.0}
    }

    r = Analysis.build(snapshot(billing))
    c = Enum.at(r.checks, 1)
    assert c.status == :mismatch
    assert_in_delta c.delta, 1.0, 0.000001
    assert r.snapshot["billing"] == billing
  end

  test "does not double count nested scripting charges or MC components" do
    b = %{
      "MonthlyChargesEUTraffic" => 1,
      "MonthlyChargesUSTraffic" => 2,
      "MonthlyChargesScripting" => 3,
      "MonthlyChargesScriptingCpu" => 2,
      "MonthlyChargesScriptingRequests" => 1,
      "MonthlyChargesMagicContainers" => 4,
      "MonthlyMcCpu" => %{"Usage" => 9},
      "MonthlyChargesWebSockets" => 0.1
    }

    assert_in_delta Enum.sum(Enum.map(Analysis.products(b), & &1.cost)), 10.1, 0.000001
  end

  test "missing observations remain unknown rather than zero" do
    s =
      snapshot(%{})
      |> Map.put("apps", [
        %{"id" => "a", "name" => "app", "statistics" => %{}, "volumes" => %{"items" => []}}
      ])

    r = Analysis.build(s)
    assert hd(r.apps)["trafficGb"] == nil
    assert hd(hd(r.apps)["days"]).traffic == nil
    assert hd(r.checks).status == :missing
  end

  test "a missing app cost cannot produce a successful aggregate reconciliation" do
    apps =
      Enum.map([1.0, nil], fn cost ->
        %{
          "id" => "a",
          "name" => "app",
          "monthlyCost" => cost,
          "statistics" => %{},
          "volumes" => %{"items" => []}
        }
      end)

    r =
      snapshot(%{"MonthlyChargesMagicContainers" => 1.0})
      |> Map.put("apps", apps)
      |> Analysis.build()

    assert r.app_sum == nil
    assert Enum.at(r.checks, 2).status == :missing
  end

  test "volume estimate clips the running day and ignores other months" do
    chart = %{
      "2026-10-01T00:00:00Z" => 10.0e9,
      "2026-10-02T00:00:00Z" => 10.0e9,
      "2026-09-30T00:00:00Z" => 100.0e9,
      "2026-10-03T00:00:00Z" => 10.0e9
    }

    assert_in_delta Analysis.volume_estimate(chart, ~D[2026-10-01], ~U[2026-10-02 12:00:00Z]),
                    1.5 / 31,
                    0.000001

    assert Analysis.volume_estimate(nil, ~D[2026-10-01], ~U[2026-10-02 12:00:00Z]) == nil
  end

  test "charts span 30 UTC days across a month boundary, preserving gaps" do
    app = %{
      "id" => "app",
      "name" => "example",
      "statistics" => %{
        "trafficChart" => %{
          "2026-09-23T00:00:00Z" => 100.0e9,
          "2026-09-24T00:00:00Z" => 1.0e9,
          "2026-10-23T00:00:00Z" => 2.0e9
        }
      },
      "volumes" => %{"items" => []}
    }

    r = snapshot(%{}) |> Map.put("apps", [app]) |> Analysis.build()
    [app] = r.apps
    assert length(app["days"]) == 30
    assert hd(app["days"]).date == "2026-09-24"
    assert List.last(app["days"]).partial
    assert Enum.at(app["days"], 1).traffic == nil
    assert_in_delta app["trafficGb"], 3.0, 0.000001
    html = Report.render_app(r, app, %{overview: "../o.html", previous: nil, next: nil})
    assert length(Regex.scan(~r/class="point"/, html)) == 120
    assert html =~ "2026-09-25 · keine Messwerte"
    refute html =~ "<th>Tag (UTC)</th>"
    assert Report.render(r, "pages") =~ ~s(href="pages/app.html")
  end

  test "cost models use this month only, clip today and never infer CPU costs" do
    stats = %{
      "ramUsageChart" => %{
        "2026-09-30T00:00:00Z" => 1000.0e9,
        "2026-10-01T00:00:00Z" => 1.0e9,
        "2026-10-02T00:00:00Z" => 1.0e9
      },
      "trafficChart" => %{"2026-09-30T00:00:00Z" => 1000.0e9, "2026-10-01T00:00:00Z" => 2.0e9},
      "volumesCapacityChart" => %{
        "2026-10-01T00:00:00Z" => 10.0e9,
        "2026-10-02T00:00:00Z" => 10.0e9
      },
      "cpuUsageChart" => %{"2026-10-01T00:00:00Z" => 123.0}
    }

    drivers = Analysis.cost_drivers(stats, ~D[2026-10-01], ~U[2026-10-02 12:00:00Z])
    assert hd(drivers).name == "RAM"
    by_name = Map.new(drivers, &{&1.name, &1})
    assert_in_delta by_name["RAM"].cost, 0.18, 0.000001
    assert_in_delta by_name["Volumes"].cost, 1.5 / 31, 0.000001
    assert_in_delta by_name["Traffic"].cost, 0.02, 0.000001
    assert by_name["Traffic"].missing_days == 1
    assert by_name["CPU"].cost == nil

    assert Enum.all?(
             Analysis.cost_drivers(%{}, ~D[2026-10-01], ~U[2026-10-02 12:00:00Z]),
             &is_nil(&1.cost)
           )
  end

  test "counts detached instances and separates run rate from incurred costs" do
    app = %{
      "id" => "a",
      "name" => "app",
      "statistics" => %{},
      "volumes" => %{
        "items" => [
          %{
            "id" => "v",
            "name" => "data",
            "size" => 3,
            "totalUsage" => 0.1,
            "volumeInstances" => [
              %{"size" => 3, "status" => "detached", "region" => "DE"},
              %{"size" => 3, "status" => "detached", "region" => "US"}
            ]
          }
        ]
      }
    }

    r = Analysis.build(Map.put(snapshot(%{}), "apps", [app]))
    assert [%{detached: true, size: 6, cost: nil, run_rate: rate}] = r.volumes
    assert_in_delta rate, 0.6, 0.000001
  end

  test "sanitizes billing payload and escapes HTML, including attribute contexts" do
    assert Collector.sanitize_billing(%{
             "Email" => "private",
             "PaymentMethods" => [],
             "MonthlyMcCpu" => %{"Usage" => 1, "Secret" => "private"}
           }) == %{"MonthlyMcCpu" => %{"Usage" => 1}}

    assert Report.escape("<script>\"&'") == "&lt;script&gt;&quot;&amp;&#39;"

    s =
      snapshot(%{})
      |> Map.put("apps", [
        %{
          "id" => "bad\"id",
          "name" => "<script>alert(1)</script>",
          "statistics" => %{},
          "volumes" => %{"items" => []}
        }
      ])

    r = Analysis.build(s)
    [app] = r.apps
    assert Report.page_file(app) == "bad_id.html"

    for html <- [
          Report.render(r, "pages"),
          Report.render_app(r, app, %{overview: "../o.html", previous: nil, next: nil})
        ] do
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end

  test "screenshot reference comparison respects rounded precision and month" do
    reference = %{
      "month" => "2026-10",
      "values" => %{"ThisMonthCharges" => 12.34},
      "labels" => %{}
    }

    assert [%{status: :ok}] =
             Analysis.compare_reference(%{"ThisMonthCharges" => 12.336}, reference, "2026-10")

    assert [] = Analysis.compare_reference(%{}, reference, "2026-11")
  end

  defp snapshot(billing),
    do: %{"fetchedAt" => "2026-10-23T06:00:00Z", "billing" => billing, "apps" => [], "cdn" => []}
end
