[fixture, expected] = System.argv()
expected = Module.concat([expected])
Code.require_file(Path.join(Path.dirname(fixture), "support.exs"))

try do
  Code.compile_file(fixture)
  IO.puts("ASH_ONETIME_FIXTURE_RESULT=compiled")
  IO.puts("ASH_ONETIME_FIXTURE_LOADED=#{Code.ensure_loaded?(expected)}")
  System.halt(0)
rescue
  error ->
    IO.puts("ASH_ONETIME_FIXTURE_RESULT=rejected")
    IO.puts("ASH_ONETIME_FIXTURE_LOADED=#{Code.ensure_loaded?(expected)}")
    IO.puts(Exception.format(:error, error, __STACKTRACE__))
    System.halt(1)
end
