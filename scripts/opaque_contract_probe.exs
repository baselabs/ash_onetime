# Temporary hosted diagnostic. Only compiled types are inspected; no application starts.
module = Postgrex.Types
{:ok, specs} = Code.Typespec.fetch_specs(module)

for {{name, arity}, definitions} <- specs,
    {name, arity} in [{:new, 1}, {:bootstrap_query, 2}, {:reload_query, 3}],
    definition <- definitions do
  quoted = Code.Typespec.spec_to_quoted(name, definition)
  IO.puts("TYPE_CONTRACT_BEAM #{name}/#{arity} #{Macro.to_string(quoted)}")
end

plt = :dialyzer_cplt.from_file(String.to_charlist(Dialyxir.Project.plt_file()))

try do
  for {name, arity} <- [{:new, 1}, {:bootstrap_query, 2}, {:reload_query, 3}] do
    mfa = {module, name, arity}
    {:value, {result, inferred}} = :dialyzer_plt.lookup(plt, mfa)
    {:value, contract} = :dialyzer_plt.lookup_contract(plt, mfa)
    {:contract, _, declared, _} = contract

    IO.puts(
      "TYPE_CONTRACT_PLT #{name}/#{arity} #{:dialyzer_contracts.contract_to_string(contract)}"
    )

    IO.puts("TYPE_CONTRACT_RETURN #{name}/#{arity} #{:erl_types.t_to_string(result)}")

    for {given, required, position} <- Enum.zip([declared, inferred, 1..arity]) do
      expected = :erl_types.t_inf(given, required)

      IO.puts(
        "TYPE_CONTRACT_ARGUMENT #{name}/#{arity} #{position} declared=#{:erl_types.t_to_string(given)} inferred=#{:erl_types.t_to_string(required)} expected=#{:erl_types.t_to_string(expected)}"
      )
    end
  end

  {:value, {new_result, new_args}} = :dialyzer_plt.lookup(plt, {module, :new, 1})
  {:value, new_contract} = :dialyzer_plt.lookup_contract(plt, {module, :new, 1})

  types =
    :erl_types.t_inf(new_result, :dialyzer_contracts.get_contract_return(new_contract, new_args))

  actual =
    :erl_types.t_map([
      {:erl_types.t_atom(:types), types},
      {:erl_types.t_atom(:disable_composite_types), :erl_types.t_any()}
    ])

  {:value, {_, reload_args}} = :dialyzer_plt.lookup(plt, {module, :reload_query, 3})

  {:value, {:contract, _, declared, _}} =
    :dialyzer_plt.lookup_contract(plt, {module, :reload_query, 3})

  expected = :erl_types.t_inf(Enum.at(declared, 2), Enum.at(reload_args, 2))
  caller = AshOnetime.Test.ExitBoundary.ConnectionStates
  conflict = :erl_types.t_opacity_conflict(actual, expected, caller)
  IO.puts("TYPE_CONTRACT_CALL actual=#{:erl_types.t_to_string(actual)} conflict=#{conflict}")
after
  :dialyzer_plt.delete(plt)
end
