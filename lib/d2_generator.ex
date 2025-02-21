defmodule Cracker.D2Generator do
  @moduledoc """
  Generates d2 diagram markup from a list of function call edges.
  Each edge is represented as [caller, callee] where caller and callee
  are strings in the format "module.function/arity"
  """

  @doc """
  Generate d2 diagram markup from a list of function call edges.

  ## Example

      edges = [
        {"MyApp.ModuleA.post/1", "MyApp.Client.post/2"},
        {"MyApp.ModuleA.post/1", "MyApp.ModuleA.persist_data/2"},
        {"MyApp.Client.post/2", "MyApp.Client.encode_query/2"},
        {"MyApp.Client.post/2", "MyApp.Client.send_request/2"}
      ]
      Cracker.D2Generator.generate(edges)
  """
  def generate(edges) do
    edge_tuples = Enum.map(edges, &to_edge_tuple/1)
    functions_by_module = group_functions(edge_tuples)
    {internal_edges, external_edges} = split_edges(edge_tuples)

    IO.iodata_to_binary([
      "direction: right",
      "# Function call graph\n",
      generate_module_containers(functions_by_module, internal_edges),
      "\n# Connections\n",
      generate_external_connections(external_edges)
    ])
  end

  defp to_edge_tuple({from, to}) do
    {parse_function(from), parse_function(to)}
  end

  defp parse_function(function_str) do
    parts = String.split(function_str, ".")
    {module_parts, [function_with_arity]} = Enum.split(parts, -1)
    module_path = Enum.join(module_parts, ".")
    [function_name, arity] = String.split(function_with_arity, "/")
    {module_path, function_name, String.to_integer(arity)}
  end

  defp group_functions(edge_tuples) do
    edge_tuples
    |> Enum.flat_map(fn {from, to} -> [from, to] end)
    |> Enum.uniq()
    |> Enum.reduce([], &group_function/2)
    |> Enum.map(fn {module, funcs} -> {module, Enum.reverse(funcs)} end)
    |> Enum.reverse()
  end

  defp group_function({module, _func, _arity} = func_tuple, acc) do
    case Enum.find(acc, fn {mod, _funcs} -> mod == module end) do
      nil ->
        [{module, [func_tuple]} | acc]

      {_mod, _funcs} ->
        Enum.map(acc, fn
          {^module, funcs} -> {module, [func_tuple | funcs]}
          other -> other
        end)
    end
  end

  defp split_edges(edge_tuples) do
    Enum.split_with(edge_tuples, fn {{m1, _, _}, {m2, _, _}} -> m1 == m2 end)
  end

  defp generate_module_containers(functions_by_module, internal_edges) do
    Enum.map(functions_by_module, fn {module, functions} ->
      [
        "#{module_name(module)}: #{module} {\n",
        generate_function_nodes(functions),
        generate_internal_connections(internal_edges, module),
        "}\n"
      ]
    end)
  end

  defp generate_function_nodes(functions) do
    Enum.map(functions, fn {module, func, arity} ->
      "  #{node_id(module, func, arity)}: #{func}/#{arity}\n"
    end)
  end

  defp generate_internal_connections(internal_edges, module) do
    internal_edges
    |> Enum.filter(fn {{m1, _, _}, {m2, _, _}} -> m1 == module and m2 == module end)
    |> Enum.map(fn {{m1, f1, a1}, {m2, f2, a2}} ->
      "  #{node_id(m1, f1, a1)} -> #{node_id(m2, f2, a2)}\n"
    end)
  end

  defp generate_external_connections(external_edges) do
    Enum.map(external_edges, fn {{from_module, from_func, from_arity}, {to_module, to_func, to_arity}} ->
      "#{module_name(from_module)}.#{node_id(from_module, from_func, from_arity)} -> " <>
        "#{module_name(to_module)}.#{node_id(to_module, to_func, to_arity)}\n"
    end)
  end

  defp node_id(_module, function, arity) do
    "#{function}_#{arity}"
  end

  defp module_name(module) do
    String.replace(module, ".", "_")
  end
end
