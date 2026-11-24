defmodule AshOnetime.MixDependencySecurityTest do
  # ADR 0004: no published requirement may resolve to a
  # version with a known unpatched advisory. Each test pins its package's consumer
  # requirement against the exact advised and patched versions from publisher/OSV
  # records, and the mutation battery mutates each requirement string to prove
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
      refute Version.match?("3.33.11", requirement)
      refute Version.match?("3.34.2", requirement)
      # EEF-CVE-2026-101028 affects Ash < 3.34.6, including the 3.34.3 floor.
      refute Version.match?("3.34.3", requirement)
      refute Version.match?("3.34.5", requirement)
      # EEF-CVE-2026-96581 affects Ash < 3.37.2, including the former 3.34.6 floor;
      # EEF-CVE-2026-114214 affects Ash < 3.37.1.
      refute Version.match?("3.34.6", requirement)
      refute Version.match?("3.36.1", requirement)
      refute Version.match?("3.37.0", requirement)
      refute Version.match?("3.37.1", requirement)
      # CVE-2026-124283 affects Ash >= 3.31.3 and < 3.38.0.
      refute Version.match?("3.37.2", requirement)
      refute Version.match?("3.37.7", requirement)
      # EEF-CVE-2026-120299 affects Ash >= 3.24.0 and < 3.38.1.
      refute Version.match?("3.38.0", requirement)
      assert Version.match?("3.38.1", requirement)
    end
  end

  @tag :deps_ash_postgres_floor_mutation
  test "ash_postgres consumer requirement rejects advised versions" do
    requirement = requirement!(:ash_postgres)
    refute Version.match?("2.12.0", requirement)
    refute Version.match?("2.13.0", requirement)
    refute Version.match?("2.14.5", requirement)
    refute Version.match?("2.15.1", requirement)
    assert Version.match?("2.15.2", requirement)
  end

  @tag :deps_ash_sql_floor_mutation
  test "ash_sql consumer requirement rejects advised versions" do
    requirement = requirement!(:ash_sql)
    refute Version.match?("0.7.0", requirement)
    # Hex retires 0.8.4/0.8.5 for query-cache security; 0.8.6 is the patched floor.
    refute Version.match?("0.7.1", requirement)
    refute Version.match?("0.8.3", requirement)
    refute Version.match?("0.8.4", requirement)
    refute Version.match?("0.8.5", requirement)
    assert Version.match?("0.8.6", requirement)
  end

  @tag :deps_db_connection_floor_mutation
  test "db_connection consumer requirement rejects advised versions" do
    requirement = requirement!(:db_connection)
    refute Version.match?("2.10.2", requirement)
    assert Version.match?("2.10.3", requirement)
  end

  @tag :deps_postgrex_floor_mutation
  test "postgrex consumer requirement rejects advised versions" do
    requirement = requirement!(:postgrex)
    refute Version.match?("0.22.0", requirement)
    refute Version.match?("0.22.1", requirement)
    refute Version.match?("0.22.2", requirement)
    refute Version.match?("0.22.3", requirement)
    assert Version.match?("0.22.4", requirement)
  end

  @tag :deps_plug_floor_mutation
  test "plug consumer requirement rejects advised versions" do
    requirement = requirement!(:plug)
    refute Version.match?("1.20.3", requirement)
    assert Version.match?("1.20.4", requirement)
  end

  @tag :deps_mint_floor_mutation
  test "mint consumer requirement rejects advised versions" do
    requirement = requirement!(:mint)
    refute Version.match?("1.9.3", requirement)
    refute Version.match?("1.10.0", requirement)
    refute Version.match?("1.10.1", requirement)
    assert Version.match?("1.10.2", requirement)
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
