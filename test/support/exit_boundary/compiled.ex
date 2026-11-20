defmodule AshOnetime.Test.ExitBoundary.Compiled do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.References

  def identity(module, name, arity) do
    References.memo({:compiled_fun, module, module.module_info(:md5), name, arity}, fn ->
      {:ok, {^module, chunks}} = :beam_lib.chunks(:code.which(module), [:atoms, ~c"FunT"])
      atoms = Map.new(chunks[:atoms])
      <<_count::32, entries::binary>> = elem(List.keyfind(chunks, ~c"FunT", 0), 1)

      entries =
        for <<atom::32, total::32, _label::32, index::32, free::32, _uniq::32 <- entries>>,
          do: {Map.fetch!(atoms, atom), total - free, index}

      {^name, ^arity, index} = Enum.find(entries, &match?({^name, ^arity, _}, &1))
      {module, name, arity, module.module_info(:md5), index}
    end)
  end

  # Symbolically execute the compiled closure's register permutation. The source
  # values are the declared callee arguments, never the checked fun's environment.
  def closure_environment(module, function, arity, callee, inputs) do
    permutation =
      References.memo(
        {:compiled_environment, module, module.module_info(:md5), function, arity, callee},
        fn ->
          {:beam_file, _, _, _, _, functions} = :beam_disasm.file(:code.which(module))
          name = String.to_existing_atom("-#{function}/#{arity}-fun-0-")

          {:function, ^name, count, _, instructions} =
            Enum.find(functions, &match?({:function, ^name, _, _, _}, &1))

          registers = Map.new(0..(count - 1), &{{:x, &1}, &1})

          registers =
            Enum.reduce_while(instructions, registers, fn
              {:swap, a, b}, regs ->
                {:cont,
                 regs |> Map.put(a, Map.fetch!(regs, b)) |> Map.put(b, Map.fetch!(regs, a))}

              {:move, from, to}, regs ->
                {:cont, Map.put(regs, to, Map.fetch!(regs, from))}

              {:call_only, ^count, {^module, ^callee, ^count}}, regs ->
                {:halt, regs}

              {tag, _}, regs when tag in [:line, :label] ->
                {:cont, regs}

              {:func_info, _, _, _}, regs ->
                {:cont, regs}

              instruction, _ ->
                raise "undeclared closure instruction: #{inspect(instruction)}"
            end)

          for n <- 0..(count - 1), do: Map.fetch!(registers, {:x, n})
        end
      )

    permutation |> Enum.zip(inputs) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end
end
