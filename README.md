# Bunny Stats

Read-only cost report for a Bunny account. Fetches data through the installed `bunny` CLI, creates a self-contained HTML file and opens it in Google Chrome on macOS. Elixir 1.19+, OTP 27+, no Hex dependencies, database or web server.

```sh
cd ~/versioned/bunny-stats
mix stats
```

The default output is `tmp/bunny-stats.html`. Each live run saves a sanitized JSON snapshot in `tmp/snapshots/`. Both are ignored by Git. Authentication stays with the Bunny CLI; the project does not read or store API keys.

```sh
mix stats --profile default
mix stats --output /tmp/bunny-stats.html
mix stats --snapshot tmp/snapshots/2026-10-23T06-00-00Z.json
mix stats --no-open  # useful for automated checks
mix test
```

The command generates HTML even when an API request fails. A failed request is shown as missing data, never as zero usage. A top-level error replaces the report with an error page, so stale results are not presented as a fresh fetch. An unavailable browser opener leaves the file available and prints its path.

## Data and accuracy

- Account total and product costs: `/billing`.
- CPU, memory, egress and volumes: actual `MonthlyMc*.Usage` values from `/billing`. These fields exist in the current response even though the public documentation is incomplete.
- App monthly totals: `/mc/apps/{id}/overview`, including inactive apps. Deleted apps are not recoverable through this listing.
- Historical daily usage: `/mc/apps/{id}/statistics?granularity=Daily`. Charts cover the last 30 UTC calendar days, including the partial current day. Fetches also include the entire current month when needed for cost models.
- Individual volumes: `/mc/apps/{id}/volumes`, including detached instances, plus historical capacity charts.
- CDN per pull zone: `/billing/summary`, checked against account CDN charges, not added again.

Historical daily billing amounts and per-app CPU/RAM/egress billing amounts are not available from these responses. CPU chart units are insufficiently documented for billing conversion. Memory telemetry does not establish billing block rounding or system overhead. Traffic telemetry does not exactly match billed egress. The report shows monthly cost drivers as explicitly labeled models: RAM daily mean GB × elapsed hours × $0.005; allocated volume GB × elapsed month fraction × $0.10; traffic as an EU/NA-egress scenario at $0.01/GB. These are not invoice allocations. RAM excludes block rounding and system overhead, and daily means can overstate short-lived workloads. Traffic may include unbilled/CDN traffic or regions with different rates. CPU stays unknown. Missing measurements are flagged. Models use current-month data only, independently of the 30-day chart window.

Volume cost estimates use decimal GB and the published rate of $0.10/GB/month. Daily capacity averages are multiplied by elapsed time within the reporting month. Within-day provisioning changes and missing measurements can affect this estimate. Current volume run rate is a separate full-month projection, not incurred cost. Replica/region instances are counted individually.

The report compares unrounded totals with a $0.005 tolerance. An optional local screenshot reference can be stored in `tmp/reference.json`; it is excluded from Git. References are compared at cent precision and only for their matching month. The report preserves discrepancies and does not claim to know their cause. Fetches are not atomic, and different endpoints may use different refresh schedules or time windows.

All generated HTML, JSON snapshots, CSV/TSV exports, logs and common credential files are ignored. Keep account-specific files in `tmp/`. Public tests contain synthetic data only.

## Layout

Account totals, app ranking, expandable cost-driver rankings, volume estimates and reconciliation. Each app shows traffic, RAM, CPU and provisioned-volume charts for the last 30 days, without a daily table. Hover, tap or keyboard focus shows the date and measurement; arrow keys navigate days, including zero and missing values. Monthly model rankings are separate from actual app billing totals. Black background, inline CSS and JavaScript, no external fonts, tracking, network requests or assets. All account strings are HTML-escaped. The report remains readable without JavaScript.

Sources: [Billing](https://bunny.net/docs/api-reference/core/billing/get-billing-details), [statistics](https://bunny.net/docs/api-reference/magic-containers/applications/get-application-statistics), [pricing](https://bunny.net/docs/magic-containers/pricing).
