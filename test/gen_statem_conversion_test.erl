%% @doc Tests that expose semantic bugs in the gen_fsm -> gen_statem conversion.
%% Each test targets a specific bug identified in the audit.
-module(gen_statem_conversion_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_core_vnode.hrl").

%% Helper: start a standalone vnode (no supervisor tree needed).
%% Uses Forward=undefined so commands are handled locally (not forwarded).
start_test_vnode() ->
    process_flag(trap_exit, true),
    {ok, Pid} = gen_statem:start_link(riak_core_vnode,
                                      [bug_mock_vnode, 0, 0, undefined],
                                      []),
    Pid.

%% {info, _F} is not a valid gen_statem event type.
%% active({info, _F}, Info, State) never matches; vnode crashes.
bug1_info_event_type() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    Pid ! {test_info_message, hello},
    timer:sleep(100),
    ?assert(is_process_alive(Pid)).

%% $gen_event used instead of $gen_cast in send_event_unreliable.
%% Message arrives as info (handle_info) instead of cast (vnode command).
bug2_gen_event_format() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    Ref = make_ref(),
    Sender = {server, ignore_ref, {self(), Ref}},
    riak_core_send_msg:send_event_unreliable(Pid,
        #riak_vnode_req_v1{sender = Sender, request = ping}),
    %% If processed as a cast/command, reply({server,ignore_ref,{Pid,Tag}}, pong)
    %% sends {Tag, pong} to Pid. If absorbed by handle_info, we get nothing.
    Got = receive {Ref, pong} -> pong after 1000 -> timeout end,
    ?assertEqual(pong, Got).

gen_statem_conversion_test_() ->
    {foreach,
     fun() -> ok end,
     fun(_) -> ok end,
     [{"Bug 1: {info, _F} is not valid gen_statem event type",
       fun bug1_info_event_type/0},
      {"Bug 2: $gen_event instead of $gen_cast",
       fun bug2_gen_event_format/0},
      {"Bug 3: unregistered sends call but handler expects cast",
       fun bug3_unregistered_call_vs_cast/0},
      {"Bug 4: send_all_proxy_req hangs caller",
       fun bug4_send_all_proxy_req/0}
     ]}.

%% send_all_proxy_req uses gen_statem:call but gen_statem From
%% is never replied to. Old code used send_all_state_event (async).
bug4_send_all_proxy_req() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    Req = #riak_vnode_req_v1{sender = ignore, request = ping},
    %% Bug: send_all_proxy_req uses gen_statem:call which blocks the
    %% caller until timeout (vnode replies via Sender, not gen_statem From).
    %% Test: send_all_proxy_req should return promptly (cast semantics).
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        catch riak_core_vnode:send_all_proxy_req(Pid, Req),
        Parent ! {Ref, returned}
    end),
    Got = receive {Ref, returned} -> returned after 2000 -> hung end,
    ?assertEqual(returned, Got).

%% unregistered/1 sends {call,From} but handler expects cast.
bug3_unregistered_call_vs_cast() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    MonRef = monitor(process, Pid),
    ok = riak_core_vnode:unregistered(Pid),
    Result = receive
        {'DOWN', MonRef, process, Pid, _} -> stopped
    after 2000 -> still_alive
    end,
    demonitor(MonRef, [flush]),
    ?assertEqual(stopped, Result).
