defmodule BunnyStats.API do
  @moduledoc "Read-only Bunny CLI adapter. Authentication stays in the CLI profile."

  def get(path, profile \\ nil) do
    args = ["api", "GET", path] ++ if(profile, do: ["--profile", profile], else: [])

    case System.find_executable("bunny") do
      nil -> {:error, "bunny CLI fehlt im PATH"}
      executable -> request(executable, args)
    end
  end

  defp request(executable, args) do
    # The CLI prints update notices on stderr. Keep them out of its JSON stream.
    # All dynamic arguments are positional, never interpolated into shell code.
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "exec \"$@\" 2>/dev/null", "bunny-stats", executable | args]
      ])

    receive_response(port, [], System.monotonic_time(:millisecond) + 45_000)
  end

  defp receive_response(port, chunks, deadline) do
    receive do
      {^port, {:data, data}} ->
        receive_response(port, [data | chunks], deadline)

      {^port, {:exit_status, 0}} ->
        case JSON.decode(chunks |> Enum.reverse() |> IO.iodata_to_binary()) do
          {:ok, data} -> {:ok, data}
          _ -> {:error, "Bunny CLI lieferte kein gültiges JSON"}
        end

      {^port, {:exit_status, code}} ->
        # Never propagate raw response bodies, credentials or account details into HTML.
        {:error, "Bunny CLI fehlgeschlagen (Exit #{code}); Profil und API-Zugriff prüfen"}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, "Bunny API hat nach 45 Sekunden nicht geantwortet"}
    end
  end
end
