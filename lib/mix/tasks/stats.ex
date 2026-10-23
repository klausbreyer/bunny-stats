defmodule Mix.Tasks.Stats do
  use Mix.Task
  @shortdoc "Read Bunny costs, write standalone HTML and open it in Google Chrome"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, output: :string, snapshot: :string, open: :boolean]
      )

    output = Path.expand(opts[:output] || "tmp/bunny-stats.html")
    File.mkdir_p!(Path.dirname(output))

    {html, status} =
      try do
        if rest != [] or invalid != [],
          do:
            raise(
              ArgumentError,
              "Aufruf: mix stats [--profile NAME] [--output DATEI.html] [--snapshot DATEI.json] [--no-open]"
            )

        result =
          if opts[:snapshot],
            do: {:ok, opts[:snapshot] |> File.read!() |> JSON.decode!()},
            else: BunnyStats.Collector.collect(opts[:profile])

        case result do
          {:ok, snapshot} ->
            if !opts[:snapshot], do: save_snapshot(snapshot)

            reference =
              if File.exists?("tmp/reference.json"),
                do: "tmp/reference.json" |> File.read!() |> JSON.decode!(),
                else: nil

            report = BunnyStats.Analysis.build(snapshot, reference)
            pages = write_app_pages(report, output)

            {BunnyStats.Report.render(report, pages),
             if(report.errors == [], do: :ok, else: :partial)}

          {:error, message} ->
            {BunnyStats.Report.error(message), :error}
        end
      rescue
        _ ->
          {BunnyStats.Report.error(
             "Bericht konnte nicht erstellt werden. JSON-Snapshot, CLI-Zugriff und Aufrufparameter prüfen."
           ), :error}
      end

    File.write!(output, html)
    File.chmod!(output, 0o600)
    Mix.shell().info(output)
    if Keyword.get(opts, :open, true), do: open_report(output)

    if status != :ok,
      do:
        Mix.shell().error(
          "Bericht enthält #{if status == :partial, do: "unvollständige Daten", else: "einen Abruffehler"}."
        )
  end

  # One HTML file per app in a directory named after the report file, e.g. tmp/bunny-stats/.
  defp write_app_pages(report, output) do
    dir = Path.rootname(output)
    File.mkdir_p!(dir)
    # Drop pages of apps that no longer exist so stale links cannot survive a run.
    dir |> Path.join("*.html") |> Path.wildcard() |> Enum.each(&File.rm!/1)
    apps = report.apps

    apps
    |> Enum.with_index()
    |> Enum.each(fn {app, i} ->
      nav = %{
        overview: "../" <> Path.basename(output),
        previous: if(i > 0, do: Enum.at(apps, i - 1)),
        next: Enum.at(apps, i + 1)
      }

      path = Path.join(dir, BunnyStats.Report.page_file(app))
      File.write!(path, BunnyStats.Report.render_app(report, app, nav))
      File.chmod!(path, 0o600)
    end)

    Path.basename(dir)
  end

  defp save_snapshot(snapshot) do
    File.mkdir_p!("tmp/snapshots")
    timestamp = String.replace(snapshot["fetchedAt"], ":", "-")
    path = "tmp/snapshots/#{timestamp}.json"
    File.write!(path, JSON.encode!(snapshot))
    File.chmod!(path, 0o600)
  end

  defp open_report(output) do
    command =
      if :os.type() == {:unix, :darwin},
        do: {"open", ["-a", "Google Chrome", output]},
        else: {"xdg-open", [output]}

    {executable, args} = command

    case System.find_executable(executable) do
      nil ->
        Mix.shell().error("Browser-Öffner fehlt. HTML-Datei manuell öffnen: #{output}")

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> Mix.shell().error("Browser konnte nicht geöffnet werden. HTML-Datei: #{output}")
        end
    end
  end
end
