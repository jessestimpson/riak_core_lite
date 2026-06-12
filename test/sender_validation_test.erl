%% @doc Tests for sender form validation and crash-safe vnode replies.
%% Unsupported sender forms (e.g. the {raw, Ref, Pid} form removed in
%% 0.10.4) used to travel unchecked into the vnode and crash it with a
%% function_clause in riak_core_vnode:reply/2, destroying the vnode's
%% in-memory state. They must instead be rejected in the caller
%% (riak_core_vnode_master) and, if one reaches a vnode anyway, the
%% reply must be dropped without killing the vnode.
-module(sender_validation_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_core_vnode.hrl").

-define(BAD_SENDERS,
        [{raw, some_ref, self_placeholder},
         {fsm, some_ref, 42},
         {server, some_ref, {not_a_pid, tag}},
         {unknown_tag, some_ref, self_placeholder},
         not_even_a_tuple]).

%% Helper: start a standalone vnode (no supervisor tree needed).
start_test_vnode() ->
    process_flag(trap_exit, true),
    {ok, Pid} = gen_statem:start_link(riak_core_vnode,
                                      [bug_mock_vnode, 0, 0, undefined],
                                      []),
    Pid.

materialize(self_placeholder) -> self();
materialize(Other) -> Other.

bad_sender(Template) ->
    list_to_tuple([materialize(E)
                   || E <- tuple_to_list(Template)]).

sender_validation_test_() ->
    {foreach,
     fun () -> ok end,
     fun (_) -> ok end,
     [{"invalid senders are rejected at the vnode master api",
       fun invalid_sender_rejected_at_master/0},
      {"valid senders still work end to end",
       fun valid_sender_round_trip/0}]}.

invalid_sender_rejected_at_master() ->
    Preflist = [{0, node()}],
    [begin
         Sender = case is_tuple(Template) of
                      true -> bad_sender(Template);
                      false -> Template
                  end,
         ?assertError({invalid_sender, _},
                      riak_core_vnode_master:command(Preflist,
                                                     ping,
                                                     Sender,
                                                     bug_mock_vnode_master)),
         ?assertError({invalid_sender, _},
                      riak_core_vnode_master:command_unreliable(Preflist,
                                                                ping,
                                                                Sender,
                                                                bug_mock_vnode_master)),
         ?assertError({invalid_sender, _},
                      riak_core_vnode_master:command_return_vnode({0, node()},
                                                                  ping,
                                                                  Sender,
                                                                  bug_mock_vnode_master)),
         ?assertError({invalid_sender, _},
                      riak_core_vnode_master:coverage(ping,
                                                      {0, node()},
                                                      [],
                                                      Sender,
                                                      bug_mock_vnode_master))
     end
     || Template <- ?BAD_SENDERS],
    ok.

valid_sender_round_trip() ->
    Pid = start_test_vnode(),
    {active, _} = riak_core_vnode:current_state(Pid),
    Ref = make_ref(),
    Sender = {server, ignore_ref, {self(), Ref}},
    riak_core_vnode:send_req(Pid,
                             #riak_vnode_req_v1{sender = Sender,
                                                request = ping}),
    Got = receive {Ref, pong} -> pong after 1000 -> timeout end,
    ?assertEqual(pong, Got).
