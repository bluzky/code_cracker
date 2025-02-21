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

    # Group by module
    module_grouped_edges = group_by_module(grouped_edges)

    IO.iodata_to_binary([
      "flowchart LR\n",
      "  %% Function call graph\n",
      generate_caller_nodes(grouped_edges),
      "\n",
      generate_module_subgraphs(module_grouped_edges),
      "\n  %% External connections\n",
      generate_connections(grouped_edges)
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

  defp group_by_module(grouped_edges) do
    Enum.group_by(grouped_edges, fn {{module, _func, _arity}, _callees} -> module end)
  end

  defp generate_caller_nodes(grouped_edges) do
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
      "  #{node_id(module, func, arity)}[\"#{module}.#{func}/#{arity}\"]\n"
    end)
  end

  defp generate_module_subgraphs(module_grouped_edges) do
    Enum.map(module_grouped_edges, fn {module, edges} ->
      module_container = module_container_id(module)

      [
        "  subgraph #{module_container}[\"#{module}\"]\n",
        "  style #{module_container} stroke-dasharray: 5 5\n",
        generate_function_subgraphs(edges),
        "  end\n"
      ]
    end)
  end

  defp generate_function_subgraphs(grouped_edges) do
    Enum.map(grouped_edges, fn {{caller_module, caller_func, caller_arity}, callees} ->
      container_name = container_id(caller_module, caller_func, caller_arity)

      [
        "    subgraph #{container_name}[\"#{caller_func}/#{caller_arity}\"]\n",
        # Generate all nodes
        generate_callee_nodes(caller_module, caller_func, caller_arity, callees),
        # Generate internal connections
        generate_callee_connections(caller_module, caller_func, caller_arity, callees),
        "    end\n"
      ]
    end)
  end

  defp generate_callee_nodes(caller_module, caller_func, caller_arity, callees) do
    callees
    |> Enum.with_index()
    |> Enum.map(fn {{_caller, {callee_module, callee_func, callee_arity}}, _idx} ->
      node = container_scoped_node_id(caller_module, caller_func, caller_arity, callee_module, callee_func, callee_arity)

      label =
        if callee_module == caller_module do
          # Internal call - simplified label
          "#{callee_func}/#{callee_arity}"
        else
          # External call - full module path
          "#{format_module_name(callee_module)}\\n#{callee_func}/#{callee_arity}"
        end

      "      #{node}[\"#{label}\"]\n"
    end)
  end

  defp generate_callee_connections(caller_module, caller_func, caller_arity, callees) do
    callees
    |> Enum.with_index()
    # Get pairs of consecutive functions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{{_caller1, callee1}, _idx1}, {{_caller2, callee2}, _idx2}] ->
      source =
        container_scoped_node_id(
          caller_module,
          caller_func,
          caller_arity,
          elem(callee1, 0),
          elem(callee1, 1),
          elem(callee1, 2)
        )

      target =
        container_scoped_node_id(
          caller_module,
          caller_func,
          caller_arity,
          elem(callee2, 0),
          elem(callee2, 1),
          elem(callee2, 2)
        )

      "      #{source} --> #{target}\n"
    end)
  end

  defp generate_connections(grouped_edges) do
    # Find all functions that are called by others
    called_functions =
      grouped_edges
      |> Enum.flat_map(fn {_caller, callees} ->
        Enum.map(callees, fn {_caller, callee} -> callee end)
      end)
      |> MapSet.new()

    Enum.flat_map(grouped_edges, fn {{caller_module, caller_func, caller_arity} = caller, callees} ->
      caller_node = node_id(caller_module, caller_func, caller_arity)
      caller_container = container_id(caller_module, caller_func, caller_arity)

      # Only create container connection if this function isn't called by others
      container_connection =
        if MapSet.member?(called_functions, caller) do
          []
        else
          ["  #{caller_node} --> #{module_container_id(caller_module)}\n"]
        end

      # Connections to other containers
      external_connections =
        callees
        |> Enum.filter(fn {_caller, callee} ->
          # Only create connections for calls to functions that are callers themselves
          Enum.any?(grouped_edges, fn {key, _} -> key == callee end)
        end)
        |> Enum.map(fn {_caller, {callee_module, callee_func, callee_arity}} ->
          source_node =
            container_scoped_node_id(
              caller_module,
              caller_func,
              caller_arity,
              callee_module,
              callee_func,
              callee_arity
            )

          if callee_module == caller_module && callee_func == caller_func && callee_arity == caller_arity do
            # Self-referential connection within the same container
            "  #{source_node} --> #{source_node}\n"
          else
            target_container = container_id(callee_module, callee_func, callee_arity)
            "  #{source_node} -.-> #{target_container}\n"
          end
        end)

      container_connection ++ external_connections
    end)
  end

  defp node_id(module, function, arity) do
    "#{String.replace(module, ".", "_")}_#{function}_#{arity}"
  end

  defp container_id(module, function, arity) do
    "#{node_id(module, function, arity)}_container"
  end

  defp module_container_id(module) do
    "#{String.replace(module, ".", "_")}_container"
  end

  defp container_scoped_node_id(container_module, container_func, container_arity, module, function, arity) do
    "#{container_id(container_module, container_func, container_arity)}_#{node_id(module, function, arity)}"
  end

  defp format_module_name(module) do
    module
  end
end
