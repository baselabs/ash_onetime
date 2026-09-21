defmodule AshOnetime.MixDependencySecurityTest do
  # ADR 0004 (2026-09-15 amendment): no published requirement may resolve to a
  # version with a known unpatched advisory. Each test pins its package's consumer
  # requirement against the exact advised and patched versions from the OSV
  # inventory, and the mutation battery mutates each requirement string to prove
  # these tests go red (deps-*-floor and deps-optional-runtime rows).
  use ExUnit.Case, async: true

  defp requirement!(package) do
    dependency = Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == package))
    assert dependency, "missing consumer constraint for #{package}"
    elem(dependency, 1)
  end

  test "ash consumer requirement rejects advised versions" do
    requirement = requirement!(:ash)

    # CI may deliberately pin Ash to a later supported version via
    # ASH_ONETIME_ASH_VERSION; the floating form is asserted in
    # test/mix/ash_pin_validation_test.exs and scripts/check_package.exs.
    unless String.starts_with?(requirement, "==") do
      refute Version.match?("3.33.3", requirement)
      assert Version.match?("3.33.4", requirement)
    end
  end

  @tag :deps_ash_postgres_floor_mutation
  test "ash_postgres consumer requirement rejects advised versions" do
    requirement = requirement!(:ash_postgres)
    refute Version.match?("2.12.0", requirement)
    assert Version.match?("2.13.0", requirement)
  end

  @tag :deps_ash_sql_floor_mutation
  test "ash_sql consumer requirement rejects advised versions" do
    requirement = requirement!(:ash_sql)
    refute Version.match?("0.7.0", requirement)
    assert Version.match?("0.7.1", requirement)
  end

  @tag :deps_mint_floor_mutation
  test "mint consumer requirement rejects advised versions" do
    requirement = requirement!(:mint)
    refute Version.match?("1.9.3", requirement)
    refute Version.match?("1.10.0", requirement)
    assert Version.match?("1.10.1", requirement)
  end

  @tag :deps_igniter_floor_mutation
  test "igniter consumer requirement rejects advised versions" do
    requirement = requirement!(:igniter)
    refute Version.match?("0.8.3", requirement)
    assert Version.match?("0.8.4", requirement)
  end

  @tag :deps_optional_runtime_mutation
  test "security constraints preserve host-owned optional runtime applications" do
    dependencies = Mix.Project.config()[:deps]

    for package <- [:plug, :oban, :igniter, :mint] do
      {^package, _requirement, options} = Enum.find(dependencies, &(elem(&1, 0) == package))
      assert options[:optional] == true
      assert options[:runtime] == false
    end

    # Exact allowlist, not a denylist: this both proves the instrument sees the
    # applications list (kernel et al. are always present) and catches any NEW
    # dependency leaking into the runtime closure. OBSERVED shape generated from
    # the runtime:true deps plus the :crypto/:logger extra applications.
    assert Enum.sort(Application.spec(:ash_onetime, :applications)) == [
             :ash,
             :ash_postgres,
             :crypto,
             :ecto_sql,
             :elixir,
             :jason,
             :kernel,
             :logger,
             :postgrex,
             :spark,
             :stdlib,
             :telemetry
           ]
  end
end
