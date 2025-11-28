defmodule Statechart.State do
  @enforce_keys [:name]
  defstruct name: nil, transitions: [], meta: %{}

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          transitions: list(),
          meta: map()
        }
end
