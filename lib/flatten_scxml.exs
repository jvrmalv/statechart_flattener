Mix.install([
  {:statifier, "~> 1.9"},
  {:jason, "~> 1.4"},
  {:xml_builder, "~> 2.1"}
])

defmodule ScxmlFlattener do
  def run(file_path, output_path) do
    # 1. Read and Parse
    xml_content = File.read!(file_path)

    with {:ok, doc, _warnings} <- Statifier.parse(xml_content),
         {:ok, state_chart} <- Statifier.initialize(doc) do

      # [FIX] Access states from the document, not the chart root
      root_states = state_chart.document.states

      if root_states == [] do
        raise "❌ No states found in document!"
      end

      # 2. Index all states (List -> Map) for O(1) lookup
      # We need this to look up parents and targets by ID.
      all_states_map = index_all_states(root_states)
      IO.puts("✅ Indexed #{map_size(all_states_map)} states.")

      # 3. Resolve Global Initial State
      # [FIX] Handle 'initial' being a list of strings
      initial_refs = state_chart.document.initial
      global_initial = resolve_initial_target(initial_refs, all_states_map)
      IO.puts("ℹ️  Global Initial State: #{global_initial}")

      # 4. Flatten
      flat_states = flatten_machine(all_states_map)

      # 5. Output/\
      write_json("#{output_path}_flat.json", flat_states, global_initial)
      write_scxml("#{output_path}_flat.scxml", flat_states, global_initial)
    else
      {:error, reason} ->
        IO.puts(:stderr, "❌ Error: #{inspect(reason)}")
    end
  end

  # --- Indexing (Tree -> Flat Map) ---

  defp index_all_states(states_list) do
    Enum.reduce(states_list, %{}, fn state, acc ->
      # 1. Add current state to map
      acc = Map.put(acc, state.id, state)

      # 2. Recurse into children
      # [FIX] Use :states key (which is a list of structs)
      child_states = Map.get(state, :states, [])

      if child_states == [] do
        acc
      else
        Map.merge(acc, index_all_states(child_states))
      end
    end)
  end

  # --- Flattening Logic ---

  defp flatten_machine(all_states) do
    # Identify Leaf States
    leaf_states =
      all_states
      |> Map.values()
      |> Enum.filter(fn state ->
         match?([], Map.get(state, :states, []))
      end)

    Enum.map(leaf_states, fn leaf ->
      %{
        "id" => leaf.id,
        "transitions" => resolve_transitions(leaf, all_states)
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp resolve_transitions(leaf, all_states) do
    ancestors = get_ancestors(leaf, all_states)
    chain = [leaf | ancestors]

    chain
    |> Enum.flat_map(fn state ->
      # Transitions are a list of structs
      Map.get(state, :transitions, [])
      |> Enum.map(fn t -> {t, state.id} end)
    end)
    |> Enum.reduce(%{}, fn {trans, source_id}, acc ->
      # [FIX] 'targets' is a LIST of strings (e.g. ["on"])
      target_id = List.first(trans.targets)

      Map.put_new(acc, trans.event, %{
        "event" => trans.event,
        "target" => resolve_initial_target([target_id], all_states),
        "source_defined" => source_id
      })
    end)
    |> Map.values()
    |> Enum.sort_by(& &1["event"])
  end

  # --- Helpers ---

  defp get_ancestors(state, all_states) do
    # [FIX] Use the 'parent' field which is an ID string (e.g. "on")
    case state.parent do
      nil -> []
      parent_id ->
        parent = Map.get(all_states, parent_id)
        # Safety check in case parent ID is valid but not in map (shouldn't happen)
        if parent, do: [parent | get_ancestors(parent, all_states)], else: []
    end
  end

  defp resolve_initial_target(nil, _), do: nil
  defp resolve_initial_target([], _), do: nil
  defp resolve_initial_target([target_id], all_states) do
    state = Map.get(all_states, target_id)

    if is_nil(state) do
      target_id
    else
      resolve_deepest_initial(state, all_states)
    end
  end

  defp resolve_deepest_initial(state, all_states) do
    children = Map.get(state, :states, [])

    if children == [] do
      state.id
    else
      # [FIX] Handle 'initial' list. If empty, default to first child.
      initial_ref =
        case state.initial do
          [id | _] -> id
          [] -> List.first(children).id
        end

      next_state = Map.get(all_states, initial_ref)
      resolve_deepest_initial(next_state, all_states)
    end
  end

  # --- Output Writers ---

  defp write_json(path, states, initial) do
    data = %{"initial" => initial, "states" => states}
    File.write!(path, Jason.encode!(data, pretty: true))
    IO.puts("✅ JSON written: #{path}")
  end

  defp write_scxml(path, states, initial) do
    import XmlBuilder
    state_elements = Enum.map(states, fn s ->
      trans = Enum.map(s["transitions"], fn t ->
        attr = if t["target"], do: %{event: t["event"], target: t["target"]}, else: %{event: t["event"]}
        {:transition, attr, nil}
      end)
      {:state, %{id: s["id"]}, trans}
    end)

    root = {:scxml, %{xmlns: "http://www.w3.org/2005/07/scxml", version: "1.0", initial: initial}, state_elements}
    File.write!(path, XmlBuilder.generate(root))
    IO.puts("✅ SCXML written: #{path}")
  end
end

[input_file, output_file] = System.argv()
ScxmlFlattener.run(input_file, output_file)
