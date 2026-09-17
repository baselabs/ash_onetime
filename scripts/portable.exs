# Shared cross-platform process spawning for this repo's gates and tests.
#
# On Windows, `mix` (and `iex`) are .cmd shims, not .exe binaries — System.cmd/3
# cannot exec them directly. Route those through `cmd /c` on win32; real .exe
# binaries (`elixir`, `git`, `node`, `escript`) resolve directly on every
# platform and need no shim. Required per-file via Code.require_file — never
# compiled into test/support, because the battery scripts run in :dev too,
# where test/support is not on the compile path.
defmodule AshOnetime.Portable do
  @moduledoc false

  # Commands that exist only as Windows .cmd shims.
  @cmd_shims ["mix", "iex"]

  def windows?, do: match?({:win32, _}, :os.type())

  def cmd(command, args, opts \\ []) do
    if windows?() and command in @cmd_shims do
      System.cmd("cmd", ["/c", command | args], opts)
    else
      System.cmd(command, args, opts)
    end
  end
end
