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

  defp process_doc(doc, xml_raw, _path, output_path) do
    # 1. EXTRACT VARIABLES
    initial_context = DataModel.extract_variables(doc, xml_raw)
    {guard_domains, display_vars} = DataModel.generate_domains(initial_context, xml_raw)
    IO.puts("ℹ️  Variables: #{inspect(Map.keys(initial_context))}")
    IO.puts("ℹ️  Guard-relevant vars: #{inspect(Map.keys(guard_domains))}")
    IO.puts("ℹ️  Display-only vars: #{inspect(display_vars)}")

    IO.puts(
      "ℹ️  Mutable domains: #{inspect(Enum.filter(guard_domains, fn {_, v} -> not is_list(v) or length(v) > 1 end) |> Enum.map(fn {k, _} -> k end))}"
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

    # 4. EXPAND STATE SPACE (only guard-relevant variables, history tracked during reachability)
    expanded_fsm = Expander.run(flat_fsm, guard_domains, history_info)
    IO.puts("ℹ️  Expanded states: #{length(expanded_fsm)}")

    # 5. RESOLVE INITIAL STATE (use history defaults for starting point)
    start_leaf = HistoryTracker.resolve_to_leaf_public(root_id, normalized)
    guard_initial = Map.take(initial_context, Map.keys(guard_domains))
    start_id = Expander.generate_id(start_leaf, guard_initial)
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
        # Check if this is a parallel state - build composite from all regions
        if Map.get(s, :is_parallel, false) == true do
          regions = Map.get(s, :states, [])

          region_leaves =
            Enum.map(regions, fn region ->
              region_fq = "#{id}_#{region.id}"
              resolve_to_leaf(region_fq, states)
            end)

          "#{id}__" <> Enum.join(region_leaves, "__")
        else
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
                      parent = get_parent(id, states)
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
  end

  defp is_pseudo_state?(id) do
    String.contains?(id, "__initial") ||
      String.contains?(id, ".entry_") ||
      String.contains?(id, "_history")
  end

  # Real parent recorded by Normalize (ids may themselves contain "_").
  defp get_parent(id, states) do
    case Map.get(states, id) do
      nil -> nil
      s -> s.parent
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
  Classify variables into guard-relevant vs display-only.
  Guard-relevant: appear in any `cond` attribute (control transition routing).
  Display-only: only appear in `assign`/`onentry` expressions (outputs only).
  Returns {guard_vars_set, display_vars_list}
  """
  def classify_variables(ctx, xml) do
    all_vars = MapSet.new(Map.keys(ctx))

    # Extract all variable names referenced in cond attributes
    guard_vars =
      if xml do
        guards =
          Regex.scan(~r/cond="([^"]+)"/, xml)
          |> Enum.map(fn [_, cond] -> HtmlEntities.decode(cond) end)

        # Extract variable references from guards (word tokens that are known variable names)
        Enum.reduce(guards, MapSet.new(), fn guard, acc ->
          # Find all word tokens in the guard expression
          tokens =
            Regex.scan(~r/[a-zA-Z_]\w*/, guard)
            |> Enum.map(fn [tok] -> tok end)
            |> Enum.filter(&MapSet.member?(all_vars, &1))

          Enum.reduce(tokens, acc, &MapSet.put(&2, &1))
        end)
      else
        all_vars
      end

    display_vars =
      MapSet.difference(all_vars, guard_vars)
      |> MapSet.to_list()

    {guard_vars, display_vars}
  end

  @doc """
  Generate domains for guard-relevant variables only.
  Returns {guard_domains, display_vars_list}.
  Guard-relevant variables get expanded domains; display-only are excluded.
  """
  def generate_domains(ctx, xml \\ nil) do
    {guard_vars, display_vars} = classify_variables(ctx, xml)

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

    # Analyze guard usage to determine minimal domains per variable
    guard_usage = if xml, do: analyze_guard_usage(xml), else: %{}

    # Only generate domains for guard-relevant variables
    guard_domains =
      ctx
      |> Enum.filter(fn {k, _} -> MapSet.member?(guard_vars, k) end)
      |> Map.new(fn {k, v} ->
        if MapSet.member?(mutable_vars, k) do
          usage = Map.get(guard_usage, k, :unknown)

          cond do
            # Boolean variable
            is_boolean(v) ->
              {k, [true, false]}

            # Time variable — check usage pattern
            is_time_variable?(k) ->
              case usage do
                :only_gt_zero ->
                  # Variable only compared with > 0: just needs [0, 1]
                  {k, [0, 1]}

                :only_equality ->
                  # Variable only in equality with other vars: just needs [0, 1]
                  {k, [0, 1]}

                _ ->
                  # Variable has numeric boundary or modular comparisons
                  boundaries = Map.get(guard_boundaries, k, [])
                  domain = generate_time_domain(boundaries)
                  {k, domain}
              end

            # Regular integer variable
            is_integer(v) ->
              boundaries = Map.get(guard_boundaries, k, [])

              if Enum.empty?(boundaries) do
                {k, 0..10}
              else
                {k, generate_boundary_domain(boundaries, 0, 10)}
              end

            # String variable in guard
            is_binary(v) ->
              string_domain = extract_string_domain(k, xml)
              {k, string_domain}

            true ->
              {k, [v]}
          end
        else
          # Constant - keep as singleton value
          {k, [v]}
        end
      end)

    {guard_domains, display_vars}
  end

  @doc """
  Analyze how each variable is used in guard conditions.
  Returns a map of variable_name => usage_type where usage_type is:
  - :only_gt_zero — only appears in `var > 0` patterns
  - :only_equality — only appears in `var == other_var` patterns (no literals)
  - :has_boundaries — appears with literal numeric comparisons/modular ops
  - :unknown — appears but usage pattern unclear
  """
  defp analyze_guard_usage(xml) do
    guards =
      Regex.scan(~r/cond="([^"]+)"/, xml)
      |> Enum.map(fn [_, cond] -> HtmlEntities.decode(cond) end)

    Enum.reduce(guards, %{}, fn guard, acc ->
      # Find all variable usage patterns in this guard
      # Pattern 1: var > 0 or var >= 1
      gt_zero_vars =
        Regex.scan(~r/(\w+)\s*>\s*0/, guard)
        |> Enum.map(fn [_, var] -> var end)

      # Pattern 2: var == other_var (not a literal number)
      eq_var_vars =
        Regex.scan(~r/(\w+)\s*==\s*([a-zA-Z_]\w*)/, guard)
        |> Enum.flat_map(fn [_, v1, v2] -> [v1, v2] end)

      # Pattern 3: var with modular (%) or numeric literal comparisons
      modular_vars =
        Regex.scan(~r/(\w+)\s*%\s*\d+/, guard)
        |> Enum.map(fn [_, var] -> var end)

      # Pattern 4: var compared with literal > 0 (e.g., var >= 864000)
      boundary_vars =
        Regex.scan(~r/(\w+)\s*[<>=!]+\s*(\d+)/, guard)
        |> Enum.filter(fn [_, _, num] -> String.to_integer(num) > 1 end)
        |> Enum.map(fn [_, var, _] -> var end)

      all_complex = MapSet.new(modular_vars ++ boundary_vars)

      # Update accumulator with usage info
      acc = Enum.reduce(gt_zero_vars, acc, fn var, a ->
        if MapSet.member?(all_complex, var) do
          Map.put(a, var, :has_boundaries)
        else
          Map.update(a, var, :only_gt_zero, fn
            :only_gt_zero -> :only_gt_zero
            _ -> :has_boundaries
          end)
        end
      end)

      acc = Enum.reduce(eq_var_vars, acc, fn var, a ->
        if MapSet.member?(all_complex, var) do
          Map.put(a, var, :has_boundaries)
        else
          Map.update(a, var, :only_equality, fn
            :only_equality -> :only_equality
            :only_gt_zero -> :only_gt_zero
            _ -> :has_boundaries
          end)
        end
      end)

      Enum.reduce(MapSet.to_list(all_complex), acc, fn var, a ->
        Map.put(a, var, :has_boundaries)
      end)
    end)
  end

  defp is_time_variable?(name) do
    name_lower = String.downcase(name)

    String.contains?(name_lower, "hour") ||
      (String.contains?(name_lower, "time") && !String.contains?(name_lower, "timeout")) ||
      String.contains?(name_lower, "minute") ||
      (String.contains?(name_lower, "second") && !String.contains?(name_lower, "per_second"))
  end

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

  @doc """
  Extract string domain for a variable from all assign expressions in the XML.
  """
  defp extract_string_domain(var_name, xml) do
    if xml do
      Regex.scan(~r/<assign\s+location="#{Regex.escape(var_name)}"\s+expr="([^"]+)"/, xml)
      |> Enum.map(fn [_, expr] -> LogicEngine.eval(expr, %{}) end)
      |> Enum.reject(&(&1 == :error))
      |> Enum.uniq()
      |> case do
        [] -> [""]
        vals -> vals
      end
    else
      [""]
    end
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

  @doc """
  Resolve In('stateName') predicates in a guard expression.
  Replaces each In('x') with true if x is a suffix of any active component ID, false otherwise.
  `active_ids` is a list of fully-qualified state IDs currently active.
  """
  def resolve_in_predicates(guard_str, active_ids) when is_binary(guard_str) do
    Regex.replace(~r/In\(\s*'([^']+)'\s*\)/, guard_str, fn _, state_name ->
      is_active =
        Enum.any?(active_ids, fn id ->
          # Match if the state_name is the ID itself or a suffix after underscore
          id == state_name ||
            String.ends_with?(id, "_#{state_name}")
        end)

      if is_active, do: "true", else: "false"
    end)
  end

  def resolve_in_predicates(nil, _active_ids), do: nil
  def resolve_in_predicates(guard_str, _active_ids), do: guard_str
end

# ==========================================
# MODULE: NORMALIZE
# ==========================================
defmodule Normalize do
  def run(states) do
    reg = discover(states, nil, %{})
    history_info = detect_history(reg)
    parallel_info = detect_parallel(reg)

    index = local_id_index(reg)

    resolved =
      Enum.map(reg, fn {id, s} ->
        {id, %{s | id: id, transitions: resolve_trans(s, id, reg, index)}}
      end)
      |> Map.new()

    root = Enum.find_value(resolved, fn {id, s} -> if is_nil(s.parent), do: id end)
    {resolved, root, history_info, parallel_info}
  end

  defp discover([], _, acc), do: acc

  defp discover([s | t], p, acc) do
    # Handle anonymous/unnamed states (e.g., top-level <parallel> with no id)
    state_id = s.id
    state_id = if is_nil(state_id) or state_id == "" or state_id == nil, do: "_root", else: state_id
    full = if p, do: "#{p}_#{state_id}", else: state_id
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

  defp resolve_trans(s, scope, reg, index) do
    Map.get(s, :transitions, [])
    |> Enum.map(fn t ->
      targets = (t.targets || []) |> Enum.map(&find(&1, scope, reg, index))
      %{t | targets: targets}
    end)
  end

  # SCXML state ids are unique within the document, so an original (local) id
  # identifies its fully-qualified id directly. Only unambiguous ids are indexed.
  # NOTE: never rebuild ancestry by splitting the flattened id on "_": "_" is both
  # the hierarchy separator and a legal character inside ids (e.g. "Getting_Dark").
  defp local_id_index(reg) do
    reg
    |> Enum.group_by(fn {_fq, s} -> s.id end, fn {fq, _s} -> fq end)
    |> Enum.flat_map(fn
      {local, [fq]} when is_binary(local) -> [{local, fq}]
      _ -> []
    end)
    |> Map.new()
  end

  defp find(tgt, scope, reg, index) do
    case Map.get(index, tgt) || Enum.find(gen_scope(scope, tgt, reg), &Map.has_key?(reg, &1)) do
      nil ->
        # Fallback: global search for any state whose ID ends with this target
        # This handles inter-level transitions across sibling subtrees
        global_match =
          reg
          |> Map.keys()
          |> Enum.filter(fn id ->
            id == tgt || String.ends_with?(id, "_#{tgt}")
          end)
          |> Enum.sort_by(&String.length/1)
          |> List.first()

        if global_match do
          global_match
        else
          if scope do
            parent = parent_of(scope, reg)
            if parent, do: "#{parent}_#{tgt}", else: tgt
          else
            tgt
          end
        end

      found ->
        found
    end
  end

  # Candidate fully-qualified ids from the innermost scope outwards (document order).
  defp gen_scope(nil, tgt, _reg), do: [tgt]
  defp gen_scope(sc, tgt, reg), do: ["#{sc}_#{tgt}" | gen_scope(parent_of(sc, reg), tgt, reg)]

  # Real parent recorded by discover/3 (nil for the root or unknown ids).
  defp parent_of(id, reg) do
    case Map.get(reg, id) do
      nil -> nil
      s -> s.parent
    end
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
    # Sort parallels from deepest to shallowest (bottom-up processing)
    sorted_parallels =
      Enum.sort_by(parallel_info, fn {id, _} -> -String.length(id) end)

    # Process bottom-up, storing composites for nested parallels
    {all_composites, composite_map} =
      Enum.reduce(sorted_parallels, {[], %{}}, fn {parallel_id, info}, {acc, cmap} ->
        regions = info.regions

        region_leaves =
          Enum.map(regions, fn region_id ->
            region_fq = "#{parallel_id}_#{region_id}"
            get_region_leaves(region_fq, states, cmap)
          end)

        composites =
          cartesian_product(region_leaves)
          |> Enum.map(fn combo ->
            # Collect all component IDs (flatten nested composites)
            all_component_ids =
              Enum.flat_map(combo, fn c ->
                if Map.get(c, :is_parallel_composite) do
                  c.component_ids
                else
                  [c.id]
                end
              end)

            composite_id = "#{parallel_id}__" <> Enum.join(Enum.map(combo, & &1.id), "__")

            %{
              id: composite_id,
              parent: parallel_id,
              is_parallel_composite: true,
              component_ids: all_component_ids,
              components: combo,
              transitions: [],
              states: [],
              onexit_actions: [],
              onentry_actions: []
            }
          end)

        {acc ++ composites, Map.put(cmap, parallel_id, composites)}
      end)

    # Only return top-level composites (those not nested inside another parallel's region)
    # plus nested composites that aren't subsumed by parent composites
    nested_parallel_ids = MapSet.new(Map.keys(parallel_info))

    # Find which parallels are nested inside others
    top_level_parallel_ids =
      Enum.reject(Map.keys(parallel_info), fn pid ->
        Enum.any?(Map.keys(parallel_info) -- [pid], fn other_pid ->
          String.starts_with?(pid, other_pid <> "_")
        end)
      end)
      |> MapSet.new()

    # Return only top-level composites
    Enum.filter(all_composites, fn c ->
      MapSet.member?(top_level_parallel_ids, c.parent)
    end)
  end

  defp get_region_leaves(region_id, states, composite_map) do
    case Map.get(states, region_id) do
      nil ->
        []

      s ->
        # Check if this state is a nested parallel
        if Map.get(s, :is_parallel, false) == true do
          # Use pre-computed composites for this nested parallel
          case Map.get(composite_map, region_id) do
            nil -> []
            composites -> composites
          end
        else
          children = Map.get(s, :states, [])

          if Enum.empty?(children) do
            if is_pseudo_state?(s.id), do: [], else: [s]
          else
            Enum.flat_map(children, fn child ->
              child_fq = "#{region_id}_#{child.id}"
              get_region_leaves(child_fq, states, composite_map)
            end)
          end
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

    # Resolve In() predicates against this composite's active component IDs
    active_component_ids = composite.component_ids

    Enum.reduce(all_transitions, [], fn {t, _src, affected_component}, acc ->
      # Resolve In() predicates in the guard condition
      resolved_cond = LogicEngine.resolve_in_predicates(t.cond, active_component_ids)

      tgt_ref = List.first(t.targets)

      tgt_id =
        if tgt_ref do
          resolve_parallel_target(tgt_ref, composite, affected_component, states, history_info)
        else
          composite.id
        end

      actions = get_transition_actions(t)

      event_name = t.event || "_auto"

      acc ++ [%{
        "event" => event_name,
        "cond" => resolved_cond,
        "target" => tgt_id,
        "actions" => actions
      }]
    end)
    |> Enum.uniq_by(fn t -> "#{t["event"]}|#{t["cond"]}" end)
  end

  defp resolve_parallel_target(tgt_ref, composite, affected_component, states, history_info) do
    parallel_id = composite.parent
    resolved_target = resolve_initial_to_leaf(tgt_ref, states, history_info)

    cond do
      # Target is within the same parallel region — update the affected component
      String.starts_with?(resolved_target, parallel_id) ->
        if affected_component do
          replace_component_in_composite(composite, affected_component, resolved_target, parallel_id)
        else
          resolved_target
        end

      # Target is a history marker — wrap it in the composite, replacing the affected component
      String.starts_with?(resolved_target, "_HISTORY_") ->
        if affected_component do
          replace_component_in_composite(composite, affected_component, resolved_target, parallel_id)
        else
          # History marker from the parallel element itself — replace the affected region
          # Try to determine which region the history parent belongs to
          "#{parallel_id}__" <> Enum.join(
            Enum.map(composite.components, fn comp ->
              # Check if this component is within the history parent
              history_parent = String.replace_prefix(resolved_target, "_HISTORY_", "")
              if String.starts_with?(comp.id, history_parent <> "_") || comp.id == history_parent do
                resolved_target
              else
                comp.id
              end
            end),
            "__"
          )
        end

      # Target exits the parallel — return as-is (cross-hierarchy transition)
      true ->
        resolved_target
    end
  end

  defp replace_component_in_composite(composite, affected_component, new_target, parallel_id) do
    new_components =
      Enum.map(composite.components, fn comp ->
        if comp.id == affected_component.id do
          %{comp | id: new_target}
        else
          comp
        end
      end)

    "#{parallel_id}__" <> Enum.join(Enum.map(new_components, & &1.id), "__")
  end

  defp get_regular_trans(leaf, states, history_info) do
    ancestry = get_ancestry(leaf, states)
    active_component_ids = Enum.map(ancestry, & &1.id)

    ancestry
    |> Enum.flat_map(fn s -> Map.get(s, :transitions, []) |> Enum.map(&{&1, s}) end)
    |> Enum.reduce([], fn {t, src}, acc ->
      resolved_cond = LogicEngine.resolve_in_predicates(t.cond, active_component_ids)

      tgt_ref = List.first(t.targets)

      tgt_id =
        if tgt_ref, do: resolve_initial_to_leaf(tgt_ref, states, history_info), else: leaf.id

      actions = get_transition_actions(t)

      event_name = t.event || "_auto"

      acc ++ [%{
        "event" => event_name,
        "cond" => resolved_cond,
        "target" => tgt_id,
        "actions" => actions
      }]
    end)
    |> Enum.uniq_by(fn t -> "#{t["event"]}|#{t["cond"]}" end)
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
    parent = get_parent_scope(current_scope, states)

    cond do
      Map.has_key?(states, target) -> target
      parent && Map.has_key?(states, "#{parent}_#{target}") -> "#{parent}_#{target}"
      true -> target
    end
  end

  # Real parent recorded by Normalize (ids may themselves contain "_").
  defp get_parent_scope(id, states) do
    case Map.get(states, id) do
      nil -> nil
      s -> s.parent
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

    # Track which variables are guard-relevant (present in domains)
    guard_var_names = MapSet.new(Map.keys(domains))

    Enum.flat_map(flat, fn s ->
      Enum.map(scenarios, fn ctx ->
        id = generate_id(s["id"], ctx)

        # Regular transitions from the statechart
        valid =
          s["transitions"]
          |> Enum.reduce([], fn t, acc ->
            result = LogicEngine.eval(t["cond"], ctx)

            if result == true or result == :error do
              is_shadowed = Enum.any?(acc, fn accepted ->
                accepted["event"] == t["event"] and accepted["eval_result"] == true
              end)

              if is_shadowed do
                acc
              else
                acc ++ [Map.put(t, "eval_result", result)]
              end
            else
              acc
            end
          end)
          |> Enum.map(fn t ->
            next_ctx = apply_actions(t["actions"], ctx, guard_var_names, domains)

            event_output = if t["eval_result"] == :error and not is_nil(t["cond"]) and t["cond"] != "" do
              "#{t["event"]} [#{t["cond"]}]"
            else
              t["event"]
            end

            %{
              "input" => event_output,
              "target" => generate_id(t["target"], next_ctx),
              "output" => t["actions"]
            }
          end)

        # Add time progression transitions
        time_transitions = generate_time_transitions(s["id"], ctx, time_vars)

        %{"state" => id, "transitions" => valid ++ time_transitions}
      end)
    end)
  end

  @doc """
  Generate transitions for time progression.
  For each time variable, add a transition to jump to the next relevant time value.
  """
  defp generate_time_transitions(base_state, ctx, time_vars) do
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

  defp apply_actions([], ctx, _guard_vars, _domains), do: ctx

  defp apply_actions([act | t], ctx, guard_vars, domains) do
    new_ctx =
      case Regex.run(~r/assign ([^=]+)=(.+)/, act) do
        [_, var, expr] ->
          # Only update guard-relevant variables; skip display-only ones
          if MapSet.member?(guard_vars, var) do
            new = LogicEngine.eval(expr, ctx)

            case new do
              :error ->
                # Expression failed (e.g. JS function or references display var) — keep current
                ctx

              val when is_integer(val) ->
                # Snap to nearest valid domain value
                snapped = snap_to_domain(var, val, domains)
                Map.put(ctx, var, snapped)

              val when is_boolean(val) ->
                Map.put(ctx, var, val)

              val ->
                Map.put(ctx, var, val)
            end
          else
            # Display-only variable — skip, don't add to context
            ctx
          end

        _ ->
          ctx
      end

    apply_actions(t, new_ctx, guard_vars, domains)
  end

  @doc """
  Snap a value to the nearest valid domain point for a variable.
  If the value equals a domain point, use it. Otherwise find the nearest.
  """
  defp snap_to_domain(var, val, domains) do
    case Map.get(domains, var) do
      nil -> val
      domain ->
        domain_list = if is_struct(domain, Range), do: Enum.to_list(domain), else: domain
        if val in domain_list do
          val
        else
          # Find nearest domain value
          Enum.min_by(domain_list, &abs(&1 - val))
        end
    end
  end
end

[file, output] = System.argv()
ScxmlCompiler.run(file, output)
