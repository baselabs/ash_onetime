defmodule AshOnetime.MixAshPinValidationTest do
  # ASH_ONETIME_ASH_VERSION must be a plain release in [3.37.2, 4.0.0).
  # Reject invalid pins during project configuration before they reach package metadata.
  # Invoke Mix with the variable set to exercise the actual public entry point.
  # --no-deps-check prevents lock mismatch from supplying an unrelated failure.
  # The guard must fail before dependency resolution.
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
    {output, exit} = mix_compile("3.37.1")

    assert exit != 0
    assert output =~ "3.37.1"
    assert output =~ "3.37.2"
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
    {_output, exit} = mix_compile("3.37.2")

    assert exit == 0
  end

  test "rejects a pre-release pin" do
    {output, exit} = mix_compile("4.0.0-rc.0")

    assert exit != 0
    assert output =~ "4.0.0-rc.0"
  end

  test "rejects a build-metadata pin" do
    {output, exit} = mix_compile("3.37.2+build5")

    assert exit != 0
    assert output =~ "3.37.2+build5"
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
