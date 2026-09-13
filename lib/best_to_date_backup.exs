Mix.install([
  {:statifier, "~> 1.9"},
  {:jason, "~> 1.4"},
  {:xml_builder, "~> 2.1"}
])

defmodule ScxmlCompiler do
  def run(file_path) do
    xml_content = File.read!(file_path)

    # 1. PARSE (Relaxed)
    case Statifier.parse(xml_content, validate: false) do
      {:ok, doc, _} ->
        process_doc(doc, xml_content, file_path)

      {:error, reason} ->
        IO.puts(:stderr, "❌ Parse Failed: #{inspect(reason)}")
    end
  end

  defp process_doc(doc, xml_raw, path) do
    # 2. EXTRACT VARIABLES (Robust)
    initial_context = DataModel.extract_variables(doc, xml_raw)
    domain = DataModel.generate_domains(initial_context)
    IO.puts("ℹ️  Variables: #{inspect(Map.keys(initial_context))}")

    # 3. NORMALIZE IDs (Lexical Scope)
    {normalized, root_id} = Normalize.run(doc.states)

    if is_nil(root_id) do
      IO.puts(:stderr, "❌ Error: Could not determine Root State.")
      System.halt(1)
    end

    # 4. FLATTEN HIERARCHY
    flat_fsm = Flatten.run(normalized)

    # 5. EXPAND STATE SPACE
    expanded_fsm = Expander.run(flat_fsm, domain)

    # 6. OUTPUT
    start_leaf = Flatten.resolve_initial(root_id, normalized)
    start_id = Expander.generate_id(start_leaf, initial_context)

    output_files(path, expanded_fsm, start_id)
  end

  defp output_files(path, fsm, initial) do
    base = Path.rootname(path)
    sorted_fsm = Enum.sort_by(fsm, & &1["state"])

    File.write!(
      "#{base}_flat.json",
      Jason.encode!(%{"initial" => initial, "states" => sorted_fsm}, pretty: true)
    )

    File.write!("#{base}_flat.scxml", ScxmlGenerator.generate(sorted_fsm, initial))

    IO.puts("✅ Success!")
    IO.puts("   JSON:  #{base}_flat.json")
    IO.puts("   SCXML: #{base}_flat.scxml")
  end
end

# ==========================================
# MODULE: SCXML GENERATOR
# ==========================================
defmodule ScxmlGenerator do
  import XmlBuilder

  def generate(fsm, initial) do
    state_elements =
      Enum.map(fsm, fn s ->
        transitions =
          Enum.map(s["transitions"], fn t ->
            # Filter actions: Keep IO (send/cancel), remove Logic (assign)
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
    # Guard against doc.datamodel being a string "ecmascript" or nil
    case doc.datamodel do
      %{} = dm ->
        Map.get(dm, :data, [])
        |> Enum.map(fn d -> {d.id, LogicEngine.eval(d.expr, %{})} end)
        |> Map.new()

      _ ->
        # Fallback to Regex if parser failed to produce a struct
        Regex.scan(~r/<data\s+([^>]+)\/?>/, xml)
        |> Enum.map(fn [_, a] ->
          {extract(a, "id"), LogicEngine.eval(extract(a, "expr"), %{})}
        end)
        |> Enum.reject(fn {k, _} -> is_nil(k) end)
        |> Map.new()
    end
  end

  defp extract(s, k), do: (Regex.run(~r/#{k}="([^"]+)"/, s) || [nil, nil]) |> Enum.at(1)

  def generate_domains(ctx) do
    Map.new(ctx, fn {k, v} -> {k, if(is_integer(v), do: 0..10, else: [true, false])} end)
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
      _ -> false
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

    resolved =
      Enum.map(reg, fn {id, s} ->
        {id, %{s | id: id, transitions: resolve_trans(s, id, reg)}}
      end)
      |> Map.new()

    root = Enum.find_value(resolved, fn {id, s} -> if is_nil(s.parent), do: id end)
    {resolved, root}
  end

  defp discover([], _, acc), do: acc

  defp discover([s | t], p, acc) do
    full = if p, do: "#{p}_#{s.id}", else: s.id
    # Statifier struct uses :states for children
    children = Map.get(s, :states, [])

    acc = Map.put(acc, full, %{s | parent: p})
    acc = discover(children, full, acc)
    discover(t, p, acc)
  end

  defp resolve_trans(s, scope, reg) do
    Map.get(s, :transitions, [])
    |> Enum.map(fn t ->
      targets = (t.targets || []) |> Enum.map(&find(&1, scope, reg))
      %{t | targets: targets}
    end)
  end

  defp find(tgt, scope, reg) do
    # Try to find target in scope hierarchy
    case Enum.find(gen_scope(scope, tgt), &Map.has_key?(reg, &1)) do
      nil ->
        # If not found, construct fully-qualified name with parent scope
        # This handles initial pseudo-states that reference sibling states
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

  defp gen_scope(sc, tgt) do
    ["#{sc}_#{tgt}" | gen_scope(get_parent(sc), tgt)]
  end

  defp get_parent(p) do
    if String.contains?(p, "_"),
      do: String.split(p, "_") |> Enum.drop(-1) |> Enum.join("_"),
      else: nil
  end
end

# ==========================================
# MODULE: FLATTEN (Defensive Fixes)
# ==========================================
defmodule Flatten do
  def run(states) do
    Enum.filter(Map.values(states), &match?([], Map.get(&1, :states, [])))
    |> Enum.map(fn l -> %{"id" => l.id, "transitions" => get_trans(l, states)} end)
  end

  defp get_trans(leaf, states) do
    get_ancestry(leaf, states)
    |> Enum.flat_map(fn s -> Map.get(s, :transitions, []) |> Enum.map(&{&1, s}) end)
    |> Enum.reduce(%{}, fn {t, src}, acc ->
      tgt_ref = List.first(t.targets)

      # Resolve target, defaulting to leaf if nil (internal transition)
      tgt_id = if tgt_ref, do: resolve_initial(tgt_ref, states), else: leaf.id

      # Defensive check: Does target exist?
      actions =
        case Map.get(states, tgt_id) do
          nil ->
            IO.puts(
              :stderr,
              "⚠️  Warning: Target state '#{tgt_id}' not found via transition from '#{src.id}'."
            )

            []

          tgt_state ->
            get_lca_actions(src, tgt_state, t, states)
        end

      Map.put_new(acc, "#{t.event}|#{t.cond}", %{
        "event" => t.event,
        "cond" => t.cond,
        "target" => tgt_id,
        "actions" => actions
      })
    end)
    |> Map.values()
  end

  def resolve_initial(id, states) do
    case Map.get(states, id) do
      # Return raw ID if state not found (avoids crash)
      nil ->
        id

      s ->
        case Map.get(s, :states, []) do
          [] ->
            id

          k ->
            raw = List.first(s.initial)
            # Always construct fully-qualified ID using the parent's ID as prefix
            first_child_fq = "#{s.id}_#{List.first(k).id}"

            next =
              if raw do
                fq = "#{s.id}_#{raw}"
                if Map.has_key?(states, fq), do: fq, else: first_child_fq
              else
                first_child_fq
              end

            resolve_initial(next, states)
        end
    end
  end

  defp get_lca_actions(src, tgt, t, states) do
    src_p = get_ancestry(src, states) |> Enum.reverse()
    tgt_p = get_ancestry(tgt, states) |> Enum.reverse()

    lca_node =
      Enum.zip(src_p, tgt_p)
      |> Enum.take_while(fn {a, b} -> a.id == b.id end)
      |> List.last()
      |> elem(0)

    # Use lca_node directly since we extracted it from the zip
    exits =
      get_ancestry(src, states)
      |> Enum.take_while(&(&1.id != lca_node.id))
      |> Enum.flat_map(&Map.get(&1, :onexit_actions, []))

    entries =
      get_ancestry(tgt, states)
      |> Enum.take_while(&(&1.id != lca_node.id))
      |> Enum.reverse()
      |> Enum.flat_map(&Map.get(&1, :onentry_actions, []))

    (exits ++ (t.actions || []) ++ entries) |> Enum.map(&parse/1)
  end

  defp get_ancestry(s, states) do
    # Defensive recursion: Check if parent exists in map
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
  def run(flat, domains) do
    scenarios = gen_scenarios(domains)

    Enum.flat_map(flat, fn s ->
      Enum.map(scenarios, fn ctx ->
        id = generate_id(s["id"], ctx)

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

        %{"state" => id, "transitions" => valid}
      end)
    end)
  end

  def generate_id(base, ctx) do
    "#{base}__" <> (Enum.sort(ctx) |> Enum.map_join("__", fn {k, v} -> "#{k}_#{v}" end))
  end

  defp gen_scenarios(d) do
    keys = Map.keys(d)
    cartesian(Map.values(d)) |> Enum.map(&Map.new(Enum.zip(keys, &1)))
  end

  # Fixed ambiguous syntax
  defp cartesian([]), do: [[]]
  defp cartesian([h | t]), do: for(i <- h, j <- cartesian(t), do: [i | j])

  defp apply_actions([], ctx), do: ctx

  defp apply_actions([act | t], ctx) do
    new_ctx =
      case Regex.run(~r/assign ([^=]+)=(.+)/, act) do
        [_, var, expr] ->
          new = LogicEngine.eval(expr, ctx)
          Map.put(ctx, var, if(is_integer(new), do: max(0, min(10, new)), else: new))

        _ ->
          ctx
      end

    apply_actions(t, new_ctx)
  end
end

[file] = System.argv()
ScxmlCompiler.run(file)
