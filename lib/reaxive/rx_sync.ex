defmodule Reaxive.Sync do
	@moduledoc """
	Implements the Reaxive Extensions as synchronous function composition similar to 
	Elixir's `Enum` and `Stream` libraries, but adheres to the `Observable` protocol. 

	# Design Idea

	The operators are used in two phases. First, they are composed to a single function, 
	which represents the sequence of the operators together with their initial accumulator
	list. The list might be empty, if no accumulator is used by the given operators (e.g. 
	if using `map` and `filter` only). 

	The second phase is the execution phase. Similar to transducers, the composed operators
	make no assumptions how the calculated values are used and how the accumulators are stored
	between two operator evaluations. This could be done as inside `Rx.Impl`, but other 
	implementations are possible. The result, i.e. which send to the consumers, is always the head
	of the accumulator, unless the reason tag is `:ignore` or `:halt`. 

	"""

	require Logger

	@type reason_t :: :cont | :ignore | :halt | :error

	@type acc_t :: list
	@type tagged_t :: {reason_t, any}
	@type reduce_t :: {tagged_t, acc_t, acc_t}
	@type reduce_fun_t :: ((tagged_t, acc_t, acc_t) -> reduce_t)
	@type step_fun_t :: ((any, acc_t, any, acc_t) -> reduce_t)


	@doc """
	This macro encodes the default behavior for reduction functions, which is capable of 
	ignoring values, of continuing work with `:on_next`, and of piping values for `:on_completed`
	and `:on_error`.

	You must provide the implementation for the `:on_next` branch. Implicit parameters are the 
	value `v` and the accumulator list `acc`, the current accumulator `a` and the new accumulator
	`new_acc`. 

	"""
	defmacro default_behavior(accu \\ nil, do: clause) do
		quote do
			{
			fn
				({{:on_next, var!(v)}, [var!(a) | var!(acc)], var!(new_acc)}) -> unquote(clause)
				({{:on_completed, nil}, [a | acc], new_acc})     -> halt(acc, a, new_acc)
				({{:on_completed, v}, [a | acc], new_acc})     -> emit_and_halt(acc, a, new_acc)
				{:cont, {:on_completed, v}, [a |acc], new_acc} -> emit_and_halt(acc, a, new_acc)
				({:ignore, v, [a | acc], new_acc})          -> ignore(v, acc, a, new_acc)
				({{:on_error, v}, [a | acc], new_acc})      -> error(v, acc, a, new_acc)
			end,
			unquote(accu)
			}
		end
	end

	## These macros build up the return values of the reducers.
	defmacro halt(acc, new_a, new_acc), do: 
		quote do: {{:on_completed, unquote(nil)}, unquote(acc), [unquote(new_a) | unquote(new_acc)]}
	defmacro emit_and_halt(acc, new_a, new_acc), do: 
		quote do: {:cont, {:on_completed, unquote(new_a)}, unquote(acc), [unquote(new_a) | unquote(new_acc)]}
	defmacro error(error, acc, new_a, new_acc), do: 
		quote do: {{:on_error, unquote(error)}, unquote(acc), [unquote(new_a) | unquote(new_acc)]}
	defmacro emit(v, acc, new_a, new_acc), do: 
		quote do: {{:on_next, unquote(v)}, unquote(acc), [unquote(new_a) | unquote(new_acc)]}
	defmacro ignore(v, acc, new_a, new_acc), do: 
		quote do: {:ignore, unquote(v), unquote(acc), [unquote(new_a) | unquote(new_acc)]}

	@doc "Reducer function for filter"
	@spec filter(((any) -> boolean)) :: {reduce_fun_t, any}
	def filter(pred) do
		default_behavior do
			case pred.(v) do 
				true  -> emit(v, acc, a, new_acc)
				false -> ignore(v, acc, a, new_acc)
			end
		end
	end
	
	@doc "Reducer function for map."
	@spec map(((any) -> any)) :: {reduce_fun_t, any}
	def map(fun) do
		default_behavior do: emit(fun.(v), acc, a, new_acc) 
	end

	@doc "Reducer function for take"
	def take(n) when n >= 0 do
		take_fun = default_behavior(n) do
			if a == 0 do
				r = halt(acc, a, new_acc)
				# IO.puts "a == 0, r = #{inspect r}"
				r
			else 
				emit(v, acc, a-1, new_acc)
			end
		end
	end

	@doc """
	This function takes an initial accumulator and three step functions. The step functions
	have as first parameter the current value, followed by the list of next accumulators, the current
	accumulator, and the list of future accumulators. The three functions handle the situation of
	the next value, of completion of the stream and of the error situation. 

	Handling the `ignore` case is part of `full_behavior` and cannot be handled by the step functions. 

	It is best to use the `halt`, `emit`, `ignore` and `error` macros to produce proper return 
	values of the three step functions. 
	"""
	@spec full_behavior(any, step_fun_t, step_fun_t, step_fun_t) :: {reduce_fun_t, any}
	def full_behavior(accu \\ nil, next_fun, comp_fun, error_fun) do
		{
			fn 
				({{:on_next, v}, [a | acc], new_acc})      -> next_fun . (v, acc, a, new_acc)
				({{:on_completed, v}, [a | acc], new_acc}) -> comp_fun . (v, acc, a, new_acc)
				({{:on_error, v}, [a | acc], new_acc})     -> error_fun . (v, acc, a, new_acc)
				({:ignore, v, [a | acc], new_acc})         -> ignore(v, acc, a, new_acc)
			end,
			accu
		}
	end

	@doc "Returns the sum of input events as sequence with exactly one event."
	def sum() do
		full_behavior(0, 
			fn(v, acc, a, new_acc) -> ignore(v, acc, v+a, new_acc) end,
			fn(v, acc, a, new_acc) -> emit_and_halt(acc, a, new_acc) end,
			fn(v, acc, a, new_acc) -> error(v, acc, a, new_acc) end)
	end

	@doc "Reducer for merging `n` streams"
	def merge(n) when n > 0 do
		full_behavior(n, 
			fn(v, acc, k, new_acc) -> emit(v, acc, k, new_acc) end, 
			fn
				(v, acc, 1, new_acc) -> halt(acc, 1, new_acc)  # last complete => complete merge
				(v, acc, k, new_acc) -> ignore(v, acc, k-1, new_acc) # ignore complete 
			end,
			fn(v, acc, k, new_acc) -> error(v, acc, k, new_acc) end
		)
	end
	

end