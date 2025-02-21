defmodule Cracker.MermaidGenerator do
  @moduledoc """
  Generates Mermaid flowchart markup from a list of function call edges.
  Each edge is represented as [caller, callee] where caller and callee
  are strings in the format "module.function/arity"
  """

  @doc """
  Generate Mermaid flowchart markup from a list of function call edges.

  ## Example
      edges = [
        {"MyApp.ModuleA.post/1", "MyApp.Client.post/2"},
        {"MyApp.ModuleA.post/1", "MyApp.ModuleA.persist_data/2"},
        {"MyApp.Client.post/2", "MyApp.Client.encode_query/2"},
        {"MyApp.Client.post/2", "MyApp.Client.send_request/2"}
      ]
      Cracker.MermaidGenerator.generate(edges)
  """
  def generate(edges) do
    # Convert edges to structured format
    structured_edges = Enum.map(edges, &to_edge_tuple/1)

    # Group by caller
    grouped_edges = group_by_caller(structured_edges)

    # Group by module and create module IDs
    {module_grouped_edges, module_ids} = edges
    |> Enum.flat_map(fn {from, to} -> [from, to] end)
    |> Enum.map(&parse_function/1)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&{&1, "m#{System.unique_integer([:positive])}"})
    |> then(fn module_ids ->
      {
        Enum.group_by(grouped_edges, fn {{module, _, _}, _} -> module end),
        Map.new(module_ids)
      }
    end)

    # Create function IDs
    function_ids = edges
    |> Enum.flat_map(fn {from, to} -> [from, to] end)
    |> Enum.map(&parse_function/1)
    |> Enum.uniq()
    |> Enum.map(fn {m, f, a} -> {"#{m}.#{f}/#{a}", "f#{System.unique_integer([:positive])}"} end)
    |> Map.new()

    IO.iodata_to_binary([
      "flowchart LR\n",
      "  %% Function call graph\n",
      generate_caller_nodes(grouped_edges, function_ids),
      "\n",
      generate_module_subgraphs(module_grouped_edges, module_ids, function_ids),
      "\n  %% External connections\n",
      generate_connections(grouped_edges, module_ids, function_ids)
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

  defp group_by_caller(edges) do
    Enum.group_by(edges, &elem(&1, 0))
  end

  defp generate_caller_nodes(grouped_edges, function_ids) do
    # Find all functions that are called by others
    called_functions =
      grouped_edges
      |> Enum.flat_map(fn {_caller, callees} ->
        Enum.map(callees, fn {_caller, callee} -> callee end)
      end)
      |> MapSet.new()

    grouped_edges
    |> Enum.filter(fn {caller, _callees} -> not MapSet.member?(called_functions, caller) end)
    |> Enum.map(fn {{module, func, arity}, _callees} ->
      func_id = function_ids["#{module}.#{func}/#{arity}"]
      "  #{func_id}[\"#{module}.#{func}/#{arity}\"]\n"
    end)
  end

  defp generate_module_subgraphs(module_grouped_edges, module_ids, function_ids) do
    module_grouped_edges
    |> Enum.map(fn {module, edges} ->
      module_id = module_ids[module]
      [
        "  subgraph #{module_id}[\"#{module}\"]\n",
        "  style #{module_id} stroke-dasharray: 5 5\n",
        generate_function_subgraphs(edges, module, function_ids),
        "  end\n"
      ]
    end)
  end

  defp generate_function_subgraphs(grouped_edges, current_module, function_ids) do
    Enum.map(grouped_edges, fn {{_caller_module, caller_func, caller_arity}, callees} ->
      func_id = function_ids["#{current_module}.#{caller_func}/#{caller_arity}"]
      [
        "    subgraph #{func_id}_box[\"#{caller_func}/#{caller_arity}\"]\n",
        # Generate all nodes
        generate_callee_nodes(current_module, callees, func_id, function_ids),
        # Generate internal connections
        generate_callee_connections(callees, func_id, function_ids),
        "    end\n"
      ]
    end)
  end

  defp generate_callee_nodes(caller_module, callees, container_id, function_ids) do
    callees
    |> Enum.with_index()
    |> Enum.map(fn {{_caller, {callee_module, callee_func, callee_arity}}, _idx} ->
      func_str = "#{callee_module}.#{callee_func}/#{callee_arity}"
      func_id = "#{container_id}_box_#{function_ids[func_str]}"
      label = if callee_module == caller_module do
        "#{callee_func}/#{callee_arity}"
      else
        "#{callee_module}.#{callee_func}/#{callee_arity}"
      end
      "      #{func_id}[\"#{label}\"]\n"
    end)
  end

  defp generate_callee_connections(callees, container_id, function_ids) do
    callees
    |> Enum.with_index()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{{_caller1, callee1}, _idx1}, {{_caller2, callee2}, _idx2}] ->
      source = "#{container_id}_box_#{function_ids["#{elem(callee1, 0)}.#{elem(callee1, 1)}/#{elem(callee1, 2)}"]}"
      target = "#{container_id}_box_#{function_ids["#{elem(callee2, 0)}.#{elem(callee2, 1)}/#{elem(callee2, 2)}"]}"
      "      #{source} --> #{target}\n"
    end)
  end

  defp generate_connections(grouped_edges, module_ids, function_ids) do
    # Find all functions that are called by others
    called_functions =
      grouped_edges
      |> Enum.flat_map(fn {_caller, callees} ->
        Enum.map(callees, fn {_caller, callee} -> callee end)
      end)
      |> MapSet.new()

    Enum.flat_map(grouped_edges, fn {{caller_module, caller_func, caller_arity} = caller, callees} ->
      caller_str = "#{caller_module}.#{caller_func}/#{caller_arity}"
      caller_id = function_ids[caller_str]

      # Only create container connection if this function isn't called by others
      container_connection =
        if MapSet.member?(called_functions, caller) do
          []
        else
          ["  #{caller_id} --> #{module_ids[caller_module]}\n"]
        end

      # Connections to other containers
      external_connections =
        callees
        |> Enum.filter(fn {_caller, callee} ->
          # Only create connections for calls to functions that are callers themselves
          Enum.any?(grouped_edges, fn {key, _} -> key == callee end)
        end)
        |> Enum.map(fn {_caller, {callee_module, callee_func, callee_arity}} ->
          callee_str = "#{callee_module}.#{callee_func}/#{callee_arity}"
          callee_id = function_ids[callee_str]
          source = "#{caller_id}_box_#{callee_id}"

          if callee_module == caller_module && callee_func == caller_func && callee_arity == caller_arity do
            # Self-referential connection within the same container
            "  #{source} --> #{source}\n"
          else
            target = "#{callee_id}_box"
            "  #{source} -.-> #{target}\n"
          end
        end)

      container_connection ++ external_connections
    end)
  end
end
