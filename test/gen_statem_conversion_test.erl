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
       fun bug4_send_all_proxy_req/0},
      {"Bug 5: send_command_after crashes vnode",
       fun bug5_send_command_after/0},
      {"Bug 6: manager event timer message format",
       fun bug6_manager_event_timer/0},
      {"Bug 7: wait_for_init missing infinity timeout",
       fun bug7_wait_for_init_timeout/0},
      {"Bug 8: _C wildcard matches call without replying",
       fun bug8_wildcard_event_type/0}
     ]}.

%% active(_C, #riak_vnode_req_v1{...}, State) matches {call, From}
%% but replies via Sender, not From. Caller hangs.
bug8_wildcard_event_type() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    Sender = {server, ignore_ref, {self(), make_ref()}},
    Req = #riak_vnode_req_v1{sender = Sender, request = ping},
    Result = (catch gen_statem:call(Pid, Req, 2000)),
    ?assertNot(is_tuple(Result) andalso element(1, Result) == 'EXIT').

%% wait_for_init uses gen_statem:call/2 (5s default) not infinity.
bug7_wait_for_init_timeout() ->
    SrcFile = filename:join(code:lib_dir(riak_core, src), "riak_core_vnode.erl"),
    {ok, Bin} = file:read_file(SrcFile),
    Src = binary_to_list(Bin),
    Lines = string:split(Src, "\n", all),
    FunLines = [L || L <- Lines,
                     string:find(L, "wait_for_init") =/= nomatch,
                     string:find(L, "gen_statem") =/= nomatch],
    HasInfinity = lists:any(fun(L) ->
        string:find(L, "infinity") =/= nomatch
    end, FunLines),
    ?assert(HasInfinity).

%% start_manager_event_timer uses erlang:start_timer which wraps
%% the message. The {send_manager_event, Event} cast is never delivered.
bug6_manager_event_timer() ->
    %% start_manager_event_timer must use erlang:send_after (not start_timer)
    %% so that '$gen_cast' arrives directly and gen_statem routes as cast.
    %% erlang:start_timer wraps in {timeout, Ref, Msg} which arrives as info.
    SrcFile = filename:join(code:lib_dir(riak_core, src), "riak_core_vnode.erl"),
    {ok, Bin} = file:read_file(SrcFile),
    Src = binary_to_list(Bin),
    Lines = string:split(Src, "\n", all),
    %% Find lines in start_manager_event_timer that use a timer function
    InFun = lists:dropwhile(
        fun(L) -> string:find(L, "start_manager_event_timer(Event") =:= nomatch end, Lines),
    FunLines = lists:takewhile(
        fun(L) -> string:find(L, "stop_manager_event_timer") =:= nomatch end,
        tl(InFun)),
    UsesStartTimer = lists:any(fun(L) ->
        string:find(L, "start_timer") =/= nomatch
    end, FunLines),
    ?assertNot(UsesStartTimer).

%% send_command_after uses erlang:start_timer which wraps the
%% message in {timeout, Ref, Msg}. This arrives as info, not as the
%% intended cast. The deferred command is never executed.
bug5_send_command_after() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    %% Trigger send_command_after inside the vnode via a cast command
    riak_core_vnode:send_command(Pid, {send_deferred, 50}),
    timer:sleep(300),
    %% Check that the deferred command was actually executed via handle_command
    {active, State} = riak_core_vnode:current_state(Pid),
    ModState = element(4, State),
    ?assertEqual(received, element(4, ModState)).

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
