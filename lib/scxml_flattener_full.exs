Mix.install([
  {:statifier, "~> 1.9"},
  {:jason, "~> 1.4"},
  {:xml_builder, "~> 2.1"}
])

defmodule ScxmlCompiler do
  def run(file_path, output_path) do
    xml_content = File.read!(file_path)

    case Statifier.parse(xml_content, validate: false) do
      {:ok, doc, _} ->
        process_doc(doc, xml_content, file_path, output_path)

      {:error, reason} ->
        IO.puts(:stderr, "❌ Parse Failed: #{inspect(reason)}")
    end
  end

  defp process_doc(doc, xml_raw, path, output_path) do
    # 1. EXTRACT VARIABLES
    initial_context = DataModel.extract_variables(doc, xml_raw)
    domain = DataModel.generate_domains(initial_context, xml_raw)
    IO.puts("ℹ️  Variables: #{inspect(Map.keys(initial_context))}")

    IO.puts(
      "ℹ️  Mutable domains: #{inspect(Enum.filter(domain, fn {_, v} -> not is_list(v) or length(v) > 1 end) |> Enum.map(fn {k, _} -> k end))}"
    )

    # 2. NORMALIZE IDs (with history and parallel detection)
    {normalized, root_id, history_info, parallel_info} = Normalize.run(doc.states)

    IO.puts("ℹ️  History states: #{inspect(Map.keys(history_info))}")
    IO.puts("ℹ️  Parallel states: #{inspect(Map.keys(parallel_info))}")

    if is_nil(root_id) do
      IO.puts(:stderr, "❌ Error: Could not determine Root State.")
      System.halt(1)
    end

    # 3. FLATTEN HIERARCHY (handling parallel and history)
    flat_fsm = Flatten.run(normalized, history_info, parallel_info)
    IO.puts("ℹ️  Flat states (before expansion): #{length(flat_fsm)}")

    # 4. EXPAND STATE SPACE (variable expansion only, history tracked during reachability)
    expanded_fsm = Expander.run(flat_fsm, domain, history_info)
    IO.puts("ℹ️  Expanded states: #{length(expanded_fsm)}")

    # 5. RESOLVE INITIAL STATE (use history defaults for starting point)
    start_leaf = HistoryTracker.resolve_to_leaf_public(root_id, normalized)
    start_id = Expander.generate_id(start_leaf, initial_context)
    IO.puts("ℹ️  Initial state: #{start_id}")

    # Initialize history context with defaults
    initial_history = HistoryTracker.initialize_history(history_info, normalized)
    IO.puts("ℹ️  History defaults: #{inspect(initial_history)}")

    # 6. REACHABILITY ANALYSIS with history tracking
    reachable_fsm =
      ReachabilityAnalyzer.filter_reachable(expanded_fsm, start_id, initial_history, history_info)

    IO.puts("ℹ️  States after reachability: #{length(reachable_fsm)}")

    # 7. POST-PROCESS: Resolve history markers to default targets
    resolved_fsm = resolve_history_markers(reachable_fsm, initial_history)

    # 8. OUTPUT
    output_files(output_path, resolved_fsm, start_id)
  end

  # Resolve _HISTORY_ markers in transition targets to their default values
  defp resolve_history_markers(fsm, history_defaults) do
    # Sort history entries by key length descending to match longer patterns first
    # This ensures modes_Automatic_Light_Sensing is matched before modes_Automatic
    sorted_history = Enum.sort_by(history_defaults, fn {k, _} -> -String.length(k) end)

    Enum.map(fsm, fn state ->
      resolved_transitions =
        Enum.map(state["transitions"], fn t ->
          target = t["target"]

          resolved_target =
            Enum.reduce(sorted_history, target, fn {parent_id, default_leaf}, acc ->
              marker = "_HISTORY_#{parent_id}__"

              if String.contains?(acc, marker) do
                # Replace the marker with the default leaf
                String.replace(acc, marker, "#{default_leaf}__")
              else
                acc
              end
            end)

          %{t | "target" => resolved_target}
        end)

      %{state | "transitions" => resolved_transitions}
    end)
  end

  defp output_files(path, fsm, initial) do
    base = Path.rootname(path)
    sorted_fsm = Enum.sort_by(fsm, & &1["state"])

    File.write!(
      "#{base}_flattened.json",
      Jason.encode!(%{"initial" => initial, "states" => sorted_fsm}, pretty: true)
    )

    File.write!("#{base}_flattened.scxml", ScxmlGenerator.generate(sorted_fsm, initial))

    IO.puts("✅ Success!")
    IO.puts("   JSON:  #{base}_flattened.json")
    IO.puts("   SCXML: #{base}_flatenned.scxml")
  end
end

# ==========================================
# MODULE: HISTORY TRACKER
# ==========================================
defmodule HistoryTracker do
  @doc """
  Public function to resolve a state ID to its deepest leaf.
  """
  def resolve_to_leaf_public(id, states), do: resolve_to_leaf(id, states)

  @doc """
  Initialize history context with default values for all history states.
  """
  def initialize_history(history_info, states) do
    Enum.reduce(history_info, %{}, fn {parent_id, history_data}, acc ->
      default_target = resolve_history_default(history_data, parent_id, states)
      Map.put(acc, parent_id, default_target)
    end)
  end

  defp resolve_history_default(history_data, parent_id, states) do
    default_target = history_data[:default_target]

    if default_target do
      fq = "#{parent_id}_#{default_target}"

      if Map.has_key?(states, fq) do
        resolve_to_leaf(fq, states)
      else
        resolve_to_leaf(default_target, states)
      end
    else
      case Map.get(states, parent_id) do
        nil ->
          parent_id

        s ->
          case Map.get(s, :states, []) do
            [] ->
              parent_id

            [first | _] ->
              fq = "#{parent_id}_#{first.id}"
              resolve_to_leaf(fq, states)
          end
      end
    end
  end

  defp resolve_to_leaf(id, states) do
    case Map.get(states, id) do
      nil ->
        id

      s ->
        children = Map.get(s, :states, [])

        if Enum.empty?(children) do
          if is_pseudo_state?(id) do
            # Follow pseudo-state transition
            case Map.get(s, :transitions, []) do
              [first | _] ->
                case List.first(first.targets) do
                  nil ->
                    id

                  target ->
                    parent = get_parent(id)
                    fq = if parent, do: "#{parent}_#{target}", else: target
                    fq = if Map.has_key?(states, fq), do: fq, else: target
                    resolve_to_leaf(fq, states)
                end

              [] ->
                id
            end
          else
            id
          end
        else
          initial = List.first(s.initial)

          next =
            if initial do
              fq = "#{id}_#{initial}"
              if Map.has_key?(states, fq), do: fq, else: "#{id}_#{List.first(children).id}"
            else
              "#{id}_#{List.first(children).id}"
            end

          resolve_to_leaf(next, states)
        end
    end
  end

  defp is_pseudo_state?(id) do
    String.contains?(id, "__initial") ||
      String.contains?(id, ".entry_") ||
      String.contains?(id, "_history")
  end

  defp get_parent(id) do
    if String.contains?(id, "_") do
      String.split(id, "_") |> Enum.drop(-1) |> Enum.join("_")
    else
      nil
    end
  end

  @doc """
  Update history when transitioning out of a state.
  Returns updated history context.
  """
  def update_on_exit(current_state_base, history_info, history_ctx) do
    # Find which history parent this state belongs to
    Enum.reduce(history_info, history_ctx, fn {parent_id, _}, ctx ->
      if String.starts_with?(current_state_base, parent_id <> "_") do
        # Extract the immediate child of parent_id from current_state_base
        # This becomes the new history value
        Map.put(ctx, parent_id, current_state_base)
      else
        ctx
      end
    end)
  end
end

# ==========================================
# MODULE: REACHABILITY ANALYZER
# ==========================================
defmodule ReachabilityAnalyzer do
  @doc """
  Filter reachable states with history tracking.
  """
  def filter_reachable(fsm, initial_id, initial_history, history_info) do
    state_map = Map.new(fsm, fn s -> {s["state"], s} end)

    # Debug: Check if initial state exists
    sample_keys = state_map |> Map.keys() |> Enum.take(3)
    IO.puts("ℹ️  Sample state keys: #{inspect(sample_keys)}")
    IO.puts("ℹ️  Initial ID exists in map: #{Map.has_key?(state_map, initial_id)}")

    # BFS with history context
    {reachable_ids, _} =
      bfs_reachable(
        [{initial_id, initial_history}],
        state_map,
        MapSet.new(),
        history_info
      )

    Enum.filter(fsm, fn s -> MapSet.member?(reachable_ids, s["state"]) end)
  end

  defp bfs_reachable([], _state_map, visited, _history_info), do: {visited, %{}}

  defp bfs_reachable([{current, history_ctx} | rest], state_map, visited, history_info) do
    if MapSet.member?(visited, current) do
      bfs_reachable(rest, state_map, visited, history_info)
    else
      visited = MapSet.put(visited, current)

      # Get transitions and resolve history targets
      next_items =
        case Map.get(state_map, current) do
          nil ->
            []

          state ->
            state["transitions"]
            |> Enum.flat_map(fn t ->
              target = t["target"]

              if is_nil(target) do
                []
              else
                # Resolve history references
                resolved_target = resolve_history_in_target(target, history_ctx)

                # Update history context based on current state exit
                current_base = extract_base_state(current)

                new_history =
                  HistoryTracker.update_on_exit(current_base, history_info, history_ctx)

                [{resolved_target, new_history}]
              end
            end)
        end

      bfs_reachable(rest ++ next_items, state_map, visited, history_info)
    end
  end

  defp resolve_history_in_target(target, history_ctx) do
    # Sort by key length descending to match longer patterns first
    # This ensures _HISTORY_modes_Automatic_Light_Sensing is matched before _HISTORY_modes_Automatic
    sorted_history = Enum.sort_by(history_ctx, fn {k, _} -> -String.length(k) end)

    # Check if any part of target contains a history reference
    Enum.reduce(sorted_history, target, fn {parent_id, history_value}, acc ->
      history_marker = "_HISTORY_#{parent_id}"

      if String.contains?(acc, history_marker) do
        String.replace(acc, history_marker, history_value)
      else
        acc
      end
    end)
  end

  defp extract_base_state(state_id) do
    # Remove variable suffix (everything after __)
    case String.split(state_id, "__", parts: 2) do
      [base | _] -> base
      _ -> state_id
    end
  end
end

# ==========================================
# MODULE: SCXML GENERATOR
# ==========================================
defmodule ScxmlGenerator do
  def generate(fsm, initial) do
    state_elements =
      Enum.map(fsm, fn s ->
        transitions =
          Enum.map(s["transitions"], fn t ->
            actions =
              (t["output"] || [])
              |> Enum.map(&string_to_tag/1)
              |> Enum.reject(&is_nil/1)

            {:transition, %{event: t["input"], target: t["target"]}, actions}
          end)

        {:state, %{id: s["state"]}, transitions}
      end)

    root =
      {:scxml, %{xmlns: "http://www.w3.org/2005/07/scxml", version: "1.0", initial: initial},
       state_elements}

    XmlBuilder.generate(root)
  end

  defp string_to_tag(str) do
    cond do
      String.starts_with?(str, "assign ") ->
        nil

      String.starts_with?(str, "history ") ->
        nil

      String.starts_with?(str, "send ") ->
        "send " <> event = str
        {:send, %{event: event}, nil}

      String.starts_with?(str, "cancel ") ->
        "cancel " <> id = str
        {:cancel, %{sendid: id}, nil}

      true ->
        nil
    end
  end
end

# ==========================================
# MODULE: DATA MODEL
# ==========================================
defmodule DataModel do
  def extract_variables(doc, xml) do
    case doc.datamodel do
      %{} = dm ->
        Map.get(dm, :data, [])
        |> Enum.map(fn d -> {d.id, LogicEngine.eval(d.expr, %{})} end)
        |> Map.new()

      _ ->
        Regex.scan(~r/<data\s+([^>]+)\/?>/, xml)
        |> Enum.map(fn [_, a] ->
          {extract(a, "id"), LogicEngine.eval(extract(a, "expr"), %{})}
        end)
        |> Enum.reject(fn {k, _} -> is_nil(k) end)
        |> Map.new()
    end
  end

  defp extract(s, k), do: (Regex.run(~r/#{k}="([^"]+)"/, s) || [nil, nil]) |> Enum.at(1)

  @doc """
  Generate domains only for variables that are actually mutated in the statechart.
  - Detects hour/time variables and uses 0-23 domain
  - Extracts guard boundaries to create minimal relevant value sets
  """
  def generate_domains(ctx, xml \\ nil) do
    # Find variables that are actually assigned (mutated)
    mutable_vars =
      if xml do
        Regex.scan(~r/<assign\s+location="([^"]+)"/, xml)
        |> Enum.map(fn [_, var] -> var end)
        |> Enum.uniq()
        |> MapSet.new()
      else
        MapSet.new(Map.keys(ctx))
      end

    # Extract relevant boundaries from guards for each variable
    guard_boundaries = if xml, do: extract_guard_boundaries(xml), else: %{}

    Map.new(ctx, fn {k, v} ->
      if MapSet.member?(mutable_vars, k) do
        cond do
          # Hour/time variable detection - use boundary-based domain
          is_time_variable?(k) ->
            boundaries = Map.get(guard_boundaries, k, [])
            domain = generate_time_domain(boundaries)
            {k, domain}

          # Regular integer variable - use full range
          is_integer(v) ->
            {k, 0..10}

          # Boolean variable
          true ->
            {k, [true, false]}
        end
      else
        # Constant - keep as singleton value
        {k, [v]}
      end
    end)
  end

  @doc """
  Detect if a variable name suggests it's a time/hour variable.
  """
  defp is_time_variable?(name) do
    name_lower = String.downcase(name)

    String.contains?(name_lower, "hour") ||
      (String.contains?(name_lower, "time") && !String.contains?(name_lower, "timeout")) ||
      String.contains?(name_lower, "minute") ||
      (String.contains?(name_lower, "second") && !String.contains?(name_lower, "per_second"))
  end

  @doc """
  Extract boundary values from guard conditions in the XML.
  Returns a map of variable_name => list of boundary values.
  """
  defp extract_guard_boundaries(xml) do
    # Find all cond attributes
    guards =
      Regex.scan(~r/cond="([^"]+)"/, xml)
      |> Enum.map(fn [_, cond] -> HtmlEntities.decode(cond) end)

    # Extract comparisons like "hour > 17", "hour < 10", "brightness >= 5"
    Enum.reduce(guards, %{}, fn guard, acc ->
      # Match patterns: var > N, var < N, var >= N, var <= N, var == N
      comparisons = Regex.scan(~r/(\w+)\s*([<>=!]+)\s*(\d+)/, guard)

      Enum.reduce(comparisons, acc, fn [_, var, _op, val], inner_acc ->
        boundary = String.to_integer(val)

        Map.update(inner_acc, var, [boundary], fn existing ->
          [boundary | existing] |> Enum.uniq() |> Enum.sort()
        end)
      end)
    end)
  end

  @doc """
  Generate a domain for time variables (0-23) focusing on boundary values.
  """
  defp generate_time_domain(boundaries) do
    if Enum.empty?(boundaries) do
      # Default time checkpoints: midnight, morning, noon, evening, night
      [0, 6, 12, 18, 23]
    else
      # Include boundary values and values just before/after
      expanded =
        Enum.flat_map(boundaries, fn b ->
          [max(0, b - 1), b, min(23, b + 1)]
        end)

      # Add start and end of day, sort and dedupe
      ([0, 23] ++ expanded)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&(&1 >= 0 and &1 <= 23))
    end
  end

  @doc """
  Generate a domain for integer variables focusing on boundary values.
  """
  defp generate_boundary_domain(boundaries, min_val, max_val) do
    # Include boundary values and values just before/after
    expanded =
      Enum.flat_map(boundaries, fn b ->
        [max(min_val, b - 1), b, min(max_val, b + 1)]
      end)

    # Add min and max, sort and dedupe
    ([min_val, max_val] ++ expanded)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(&1 >= min_val and &1 <= max_val))
  end
end

# HTML entity decoder for guard conditions
defmodule HtmlEntities do
  def decode(str) do
    str
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
  end
end

# ==========================================
# MODULE: LOGIC ENGINE
# ==========================================
defmodule LogicEngine do
  def eval(str, ctx) when is_binary(str) do
    try do
      binds = Enum.map(ctx, fn {k, v} -> {String.to_atom(k), v} end)
      {res, _} = Code.eval_string(str, binds)
      res
    rescue
      _ -> :error
    end
  end

  def eval(_, _), do: true
end

# ==========================================
# MODULE: NORMALIZE
# ==========================================
defmodule Normalize do
  def run(states) do
    reg = discover(states, nil, %{})
    history_info = detect_history(reg)
    parallel_info = detect_parallel(reg)

    resolved =
      Enum.map(reg, fn {id, s} ->
        {id, %{s | id: id, transitions: resolve_trans(s, id, reg)}}
      end)
      |> Map.new()

    root = Enum.find_value(resolved, fn {id, s} -> if is_nil(s.parent), do: id end)
    {resolved, root, history_info, parallel_info}
  end

  defp discover([], _, acc), do: acc

  defp discover([s | t], p, acc) do
    full = if p, do: "#{p}_#{s.id}", else: s.id
    children = Map.get(s, :states, [])

    state_with_meta = %{s | parent: p}

    # Check for history type (Statifier uses :history_type field)
    state_with_meta =
      if Map.get(s, :history_type),
        do: Map.put(state_with_meta, :is_history, true),
        else: state_with_meta

    # Check for parallel type (Statifier uses :type field with value :parallel)
    state_with_meta =
      if Map.get(s, :type) == :parallel,
        do: Map.put(state_with_meta, :is_parallel, true),
        else: state_with_meta

    acc = Map.put(acc, full, state_with_meta)
    acc = discover(children, full, acc)
    discover(t, p, acc)
  end

  defp detect_history(states) do
    Enum.reduce(states, %{}, fn {id, s}, acc ->
      is_history = Map.get(s, :is_history, false) == true || is_history_pseudo_state?(s)

      if is_history do
        parent_id = s.parent
        default_target = get_history_default(s)
        Map.put(acc, parent_id, %{history_id: id, default_target: default_target})
      else
        acc
      end
    end)
  end

  defp is_history_pseudo_state?(s) do
    id_str = to_string(Map.get(s, :id, ""))
    String.contains?(id_str, ".entry_") || String.contains?(id_str, "_history")
  end

  defp get_history_default(s) do
    case Map.get(s, :transitions, []) do
      [first | _] -> List.first(first.targets)
      [] -> nil
    end
  end

  defp detect_parallel(states) do
    Enum.reduce(states, %{}, fn {id, s}, acc ->
      if Map.get(s, :is_parallel, false) == true do
        regions = Map.get(s, :states, []) |> Enum.map(& &1.id)
        Map.put(acc, id, %{regions: regions})
      else
        acc
      end
    end)
  end

  defp resolve_trans(s, scope, reg) do
    Map.get(s, :transitions, [])
    |> Enum.map(fn t ->
      targets = (t.targets || []) |> Enum.map(&find(&1, scope, reg))
      %{t | targets: targets}
    end)
  end

  defp find(tgt, scope, reg) do
    case Enum.find(gen_scope(scope, tgt), &Map.has_key?(reg, &1)) do
      nil ->
        if scope do
          parent = get_parent(scope)
          if parent, do: "#{parent}_#{tgt}", else: tgt
        else
          tgt
        end

      found ->
        found
    end
  end

  defp gen_scope(nil, tgt), do: [tgt]
  defp gen_scope(sc, tgt), do: ["#{sc}_#{tgt}" | gen_scope(get_parent(sc), tgt)]

  defp get_parent(p) do
    if String.contains?(p, "_"),
      do: String.split(p, "_") |> Enum.drop(-1) |> Enum.join("_"),
      else: nil
  end
end

# ==========================================
# MODULE: FLATTEN
# ==========================================
defmodule Flatten do
  def run(states, history_info, parallel_info) do
    leaves =
      Enum.filter(Map.values(states), fn s ->
        is_leaf?(s) and not is_pseudo_state?(s.id)
      end)

    parallel_composites = create_parallel_composites(parallel_info, states)

    # Debug parallel composites
    IO.puts("ℹ️  Parallel composites count: #{length(parallel_composites)}")

    if length(parallel_composites) > 0 do
      sample = Enum.take(parallel_composites, 2)
      IO.puts("ℹ️  Sample composites: #{inspect(Enum.map(sample, & &1.id))}")
    end

    all_states =
      if Enum.empty?(parallel_composites) do
        leaves
      else
        parallel_leaf_ids = MapSet.new(Enum.flat_map(parallel_composites, & &1.component_ids))
        filtered_leaves = Enum.reject(leaves, fn l -> MapSet.member?(parallel_leaf_ids, l.id) end)
        filtered_leaves ++ parallel_composites
      end

    Enum.map(all_states, fn l ->
      %{
        "id" => l.id,
        "transitions" => get_trans(l, states, history_info),
        "is_parallel_composite" => Map.get(l, :is_parallel_composite, false)
      }
    end)
  end

  defp is_leaf?(s), do: Enum.empty?(Map.get(s, :states, []))

  defp is_pseudo_state?(id) do
    String.contains?(id, "__initial") ||
      String.contains?(id, ".entry_") ||
      String.contains?(id, "_history")
  end

  defp create_parallel_composites(parallel_info, states) do
    Enum.flat_map(parallel_info, fn {parallel_id, info} ->
      regions = info.regions

      region_leaves =
        Enum.map(regions, fn region_id ->
          region_fq = "#{parallel_id}_#{region_id}"
          get_region_leaves(region_fq, states)
        end)

      cartesian_product(region_leaves)
      |> Enum.map(fn combo ->
        composite_id = "#{parallel_id}__" <> Enum.join(Enum.map(combo, & &1.id), "__")

        %{
          id: composite_id,
          parent: parallel_id,
          is_parallel_composite: true,
          component_ids: Enum.map(combo, & &1.id),
          components: combo,
          transitions: [],
          states: [],
          onexit_actions: [],
          onentry_actions: []
        }
      end)
    end)
  end

  defp get_region_leaves(region_id, states) do
    case Map.get(states, region_id) do
      nil ->
        []

      s ->
        children = Map.get(s, :states, [])

        if Enum.empty?(children) do
          if is_pseudo_state?(s.id), do: [], else: [s]
        else
          Enum.flat_map(children, fn child ->
            child_fq = "#{region_id}_#{child.id}"
            get_region_leaves(child_fq, states)
          end)
        end
    end
  end

  defp cartesian_product([]), do: [[]]

  defp cartesian_product([head | tail]) do
    for h <- head, t <- cartesian_product(tail), do: [h | t]
  end

  defp get_trans(leaf, states, history_info) do
    if Map.get(leaf, :is_parallel_composite) do
      get_parallel_trans(leaf, states, history_info)
    else
      get_regular_trans(leaf, states, history_info)
    end
  end

  defp get_parallel_trans(composite, states, history_info) do
    component_transitions =
      Enum.flat_map(composite.components, fn comp ->
        get_ancestry(comp, states)
        |> Enum.flat_map(fn s ->
          Map.get(s, :transitions, [])
          |> Enum.map(&{&1, s, comp})
        end)
      end)

    parent_id = composite.parent

    parallel_transitions =
      case Map.get(states, parent_id) do
        nil ->
          []

        ps ->
          Map.get(ps, :transitions, [])
          |> Enum.map(&{&1, ps, nil})
      end

    all_transitions = component_transitions ++ parallel_transitions

    Enum.reduce(all_transitions, %{}, fn {t, src, affected_component}, acc ->
      tgt_ref = List.first(t.targets)

      tgt_id =
        if tgt_ref do
          resolve_parallel_target(tgt_ref, composite, affected_component, states, history_info)
        else
          composite.id
        end

      actions = get_transition_actions(t)

      event_name = t.event || "_auto"

      Map.put_new(acc, "#{event_name}|#{t.cond}", %{
        "event" => event_name,
        "cond" => t.cond,
        "target" => tgt_id,
        "actions" => actions
      })
    end)
    |> Map.values()
  end

  defp resolve_parallel_target(tgt_ref, composite, affected_component, states, history_info) do
    parallel_id = composite.parent
    resolved_target = resolve_initial_to_leaf(tgt_ref, states, history_info)

    if String.starts_with?(resolved_target, parallel_id) do
      if affected_component do
        new_components =
          Enum.map(composite.components, fn comp ->
            if comp.id == affected_component.id do
              %{comp | id: resolved_target}
            else
              comp
            end
          end)

        "#{parallel_id}__" <> Enum.join(Enum.map(new_components, & &1.id), "__")
      else
        resolved_target
      end
    else
      resolved_target
    end
  end

  defp get_regular_trans(leaf, states, history_info) do
    get_ancestry(leaf, states)
    |> Enum.flat_map(fn s -> Map.get(s, :transitions, []) |> Enum.map(&{&1, s}) end)
    |> Enum.reduce(%{}, fn {t, src}, acc ->
      tgt_ref = List.first(t.targets)

      tgt_id =
        if tgt_ref, do: resolve_initial_to_leaf(tgt_ref, states, history_info), else: leaf.id

      actions = get_transition_actions(t)

      event_name = t.event || "_auto"

      Map.put_new(acc, "#{event_name}|#{t.cond}", %{
        "event" => event_name,
        "cond" => t.cond,
        "target" => tgt_id,
        "actions" => actions
      })
    end)
    |> Map.values()
  end

  defp get_transition_actions(t) do
    (t.actions || []) |> Enum.map(&parse/1)
  end

  @doc """
  Resolve a state ID to its deepest leaf state.
  If the target is a history state, return a special marker.
  """
  def resolve_initial_to_leaf(id, states, history_info) do
    # Check if this ID has a history pseudo-state as its initial
    case Map.get(history_info, id) do
      nil ->
        resolve_regular(id, states, history_info)

      _history_data ->
        # Target has history - use special marker
        "_HISTORY_#{id}"
    end
  end

  defp resolve_regular(id, states, history_info) do
    case Map.get(states, id) do
      nil ->
        id

      s ->
        # Check if this is a parallel state
        if Map.get(s, :is_parallel, false) == true do
          resolve_parallel_to_composite(id, s, states, history_info)
        else
          if is_pseudo_state?(s.id) do
            case Map.get(s, :transitions, []) do
              [first | _] ->
                case List.first(first.targets) do
                  nil ->
                    id

                  target ->
                    fq = find_fq_target(target, s.id, states)
                    resolve_initial_to_leaf(fq, states, history_info)
                end

              [] ->
                id
            end
          else
            case Map.get(s, :states, []) do
              [] ->
                id

              children ->
                initial_target = List.first(s.initial)

                if initial_target do
                  fq = "#{s.id}_#{initial_target}"
                  # Check if this targets a history pseudo-state
                  if is_pseudo_state?(fq) do
                    # Check if it's a history marker pattern
                    target_state = Map.get(states, fq)

                    if target_state && Map.get(target_state, :is_history, false) == true do
                      # This initial targets history
                      "_HISTORY_#{s.id}"
                    else
                      resolve_initial_to_leaf(fq, states, history_info)
                    end
                  else
                    if Map.has_key?(states, fq) do
                      resolve_initial_to_leaf(fq, states, history_info)
                    else
                      first_child_fq = "#{s.id}_#{List.first(children).id}"
                      resolve_initial_to_leaf(first_child_fq, states, history_info)
                    end
                  end
                else
                  first_child_fq = "#{s.id}_#{List.first(children).id}"
                  resolve_initial_to_leaf(first_child_fq, states, history_info)
                end
            end
          end
        end
    end
  end

  @doc """
  Resolve a parallel state to its composite ID.
  Gets each region's initial leaf and combines them.
  """
  defp resolve_parallel_to_composite(parallel_id, parallel_state, states, history_info) do
    regions = Map.get(parallel_state, :states, [])

    # Resolve each region to its initial leaf
    region_leaves =
      Enum.map(regions, fn region ->
        region_fq = "#{parallel_id}_#{region.id}"
        resolve_initial_to_leaf(region_fq, states, history_info)
      end)

    # Build composite ID
    "#{parallel_id}__" <> Enum.join(region_leaves, "__")
  end

  defp find_fq_target(target, current_scope, states) do
    parent = get_parent_scope(current_scope)

    cond do
      Map.has_key?(states, target) -> target
      parent && Map.has_key?(states, "#{parent}_#{target}") -> "#{parent}_#{target}"
      true -> target
    end
  end

  defp get_parent_scope(id) do
    if String.contains?(id, "_") do
      String.split(id, "_") |> Enum.drop(-1) |> Enum.join("_")
    else
      nil
    end
  end

  defp get_ancestry(s, states) do
    if s.parent && Map.has_key?(states, s.parent) do
      [s | get_ancestry(Map.get(states, s.parent), states)]
    else
      [s]
    end
  end

  defp parse(%{expr: e, location: l}), do: "assign #{l}=#{e}"
  defp parse(%{event: e}), do: "send #{e}"
  defp parse(%{sendid: i}), do: "cancel #{i}"
  defp parse(_), do: "unknown"
end

# ==========================================
# MODULE: EXPANDER
# ==========================================
defmodule Expander do
  @doc """
  Expand state space with variable combinations.
  Also adds time progression transitions for time variables.
  """
  def run(flat, domains, _history_info) do
    scenarios = gen_scenarios(domains)

    # Identify time variables and their sorted domains
    time_vars =
      Enum.filter(domains, fn {k, _} -> is_time_variable?(k) end)
      |> Map.new()

    Enum.flat_map(flat, fn s ->
      Enum.map(scenarios, fn ctx ->
        id = generate_id(s["id"], ctx)

        # Regular transitions from the statechart
        valid =
          s["transitions"]
          |> Enum.filter(fn t -> LogicEngine.eval(t["cond"], ctx) end)
          |> Enum.map(fn t ->
            next_ctx = apply_actions(t["actions"], ctx)

            %{
              "input" => t["event"],
              "target" => generate_id(t["target"], next_ctx),
              "output" => t["actions"]
            }
          end)

        # Add time progression transitions
        time_transitions = generate_time_transitions(s["id"], ctx, time_vars, domains)

        %{"state" => id, "transitions" => valid ++ time_transitions}
      end)
    end)
  end

  @doc """
  Generate transitions for time progression.
  For each time variable, add a transition to jump to the next relevant time value.
  """
  defp generate_time_transitions(base_state, ctx, time_vars, domains) do
    Enum.flat_map(time_vars, fn {var_name, time_domain} ->
      current_val = Map.get(ctx, var_name, 0)
      sorted_domain = Enum.sort(time_domain)

      # Find the next value in the domain (wrap around at end)
      next_val = find_next_time_value(current_val, sorted_domain)

      if next_val && next_val != current_val do
        next_ctx = Map.put(ctx, var_name, next_val)

        [
          %{
            "input" => "time.advance.#{var_name}",
            "target" => generate_id(base_state, next_ctx),
            "output" => ["assign #{var_name}=#{next_val}"]
          }
        ]
      else
        []
      end
    end)
  end

  defp find_next_time_value(current, sorted_domain) do
    # Find the next value greater than current, or wrap to first
    case Enum.find(sorted_domain, fn v -> v > current end) do
      # Wrap around
      nil -> List.first(sorted_domain)
      next -> next
    end
  end

  defp is_time_variable?(name) do
    name_lower = String.downcase(name)

    String.contains?(name_lower, "hour") ||
      (String.contains?(name_lower, "time") && !String.contains?(name_lower, "timeout") &&
         !String.contains?(name_lower, "wait_time"))
  end

  def generate_id(base, ctx) do
    if Enum.empty?(ctx) do
      base <> "__"
    else
      "#{base}__" <> (Enum.sort(ctx) |> Enum.map_join("__", fn {k, v} -> "#{k}_#{v}" end))
    end
  end

  defp gen_scenarios(d) do
    keys = Map.keys(d)

    if Enum.empty?(keys) do
      [%{}]
    else
      cartesian(Map.values(d)) |> Enum.map(&Map.new(Enum.zip(keys, &1)))
    end
  end

  defp cartesian([]), do: [[]]
  defp cartesian([h | t]), do: for(i <- h, j <- cartesian(t), do: [i | j])

  defp apply_actions([], ctx), do: ctx

  defp apply_actions([act | t], ctx) do
    new_ctx =
      case Regex.run(~r/assign ([^=]+)=(.+)/, act) do
        [_, var, expr] ->
          new = LogicEngine.eval(expr, ctx)

          case new do
            :error ->
              # Expression failed (e.g. JS function like get_hour()) — keep current value
              ctx

            val when is_integer(val) ->
              # Clamp to valid range
              max_val = if is_time_variable?(var), do: 23, else: 10
              Map.put(ctx, var, max(0, min(max_val, val)))

            val ->
              Map.put(ctx, var, val)
          end

        _ ->
          ctx
      end

    apply_actions(t, new_ctx)
  end
end

[file, output] = System.argv()
ScxmlCompiler.run(file, output)
