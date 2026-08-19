defmodule AshOnetime.MixAshPinValidationTest do
  # Ticket #13: the ASH_ONETIME_ASH_VERSION pin branch in mix.exs ash_requirement/0
  # must fail closed at project-config evaluation time when the pinned value is not a
  # version inside the published range [3.31.3, 4.0.0). A publish with an invalid pin
  # exported would otherwise freeze a wrong "==" requirement into the hex package
  # silently. This drives the REAL surface — a mix invocation with the variable set,
  # exactly how a mis-pinned publish or CI cell hits it — rather than calling the
  # private function.
  #
  # `mix compile --no-deps-check` is the trigger: --no-deps-check keeps a lock/pin
  # MISMATCH from failing the command on its own (pre-fix, a sub-floor pin exits 0 —
  # the observable RED), while config evaluation happens before dependency checking,
  # so the guard's raise fires first when present. The requirement STRING for valid
  # pins is proven by the CI matrix cells resolving against the committed lock, not
  # re-asserted here.
  use ExUnit.Case, async: false

  @pin_var "ASH_ONETIME_ASH_VERSION"

  defp mix_compile(pin) do
    System.cmd("mix", ["compile", "--no-deps-check"],
      env: %{@pin_var => pin},
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  @tag :mixpin_ash_floor_mutation
  test "rejects a below-floor pin at config evaluation" do
    {output, exit} = mix_compile("3.31.1")

    assert exit != 0
    assert output =~ "3.31.1"
    assert output =~ "3.31.3"
  end

  test "rejects a non-version pin" do
    {output, exit} = mix_compile("banana")

    assert exit != 0
    assert output =~ "banana"
  end

  test "rejects an out-of-range 4.x pin" do
    {output, exit} = mix_compile("4.0.0")

    assert exit != 0
    assert output =~ "4.0.0"
  end

  test "accepts the floor pin" do
    {_output, exit} = mix_compile("3.31.3")

    assert exit == 0
  end

  test "rejects a pre-release pin" do
    {output, exit} = mix_compile("4.0.0-rc.0")

    assert exit != 0
    assert output =~ "4.0.0-rc.0"
  end

  test "rejects a build-metadata pin" do
    {output, exit} = mix_compile("3.31.3+build5")

    assert exit != 0
    assert output =~ "3.31.3+build5"
  end

  test "keeps the floating default when the variable is unset" do
    # CI exports ASH_ONETIME_ASH_VERSION at job level for both matrix cells, so the
    # parent environment cannot prove the unset path — a nil value in the child env
    # deterministically UNSETS the variable for the subprocess instead.
    {output, exit} =
      System.cmd("mix", ["compile", "--no-deps-check"],
        env: %{@pin_var => nil},
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert exit == 0
    refute output =~ "** (Mix)"
  end
end
