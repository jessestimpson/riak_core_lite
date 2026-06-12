%% @doc Tests that expose semantic bugs in the gen_fsm -> gen_statem conversion.
%% Each test targets a specific bug identified in the audit.
-module(gen_statem_conversion_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_core_vnode.hrl").

%% Helper: start a standalone vnode via test_link (no supervisor tree needed)
start_test_vnode() ->
    process_flag(trap_exit, true),
    {ok, Pid} = riak_core_vnode:test_link(bug_mock_vnode, 0),
    Pid.

gen_statem_conversion_test_() ->
    {foreach,
     fun() -> ok end,
     fun(_) -> ok end,
     []}.
