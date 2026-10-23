defmodule BunnyStats.APITest do
  use ExUnit.Case, async: false

  test "keeps CLI diagnostics separate and passes the query as a literal argument" do
    directory = Path.join(System.tmp_dir!(), "bunny-stats-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    path = Path.join(directory, "bunny")

    File.write!(
      path,
      "#!/bin/sh\nprintf 'Update available\\n' >&2\nif [ \"$3\" = '/test?literal=$(false)&x=1' ]; then printf '{\"ok\":true}'; else exit 3; fi\n"
    )

    File.chmod!(path, 0o700)
    original = System.get_env("PATH")
    System.put_env("PATH", directory)

    try do
      assert {:ok, %{"ok" => true}} = BunnyStats.API.get("/test?literal=$(false)&x=1")
      assert {:error, message} = BunnyStats.API.get("/wrong")
      assert message =~ "Exit 3"
      refute message =~ "Update available"
    after
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
      File.rm_rf!(directory)
    end
  end
end
