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

    html = s |> Analysis.build() |> Report.render()
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "bad&quot;id"
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
