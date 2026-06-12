%% @doc Extended mock vnode for testing gen_statem conversion bugs.
%% Adds handle_info/2 and send_command_after support.
-module(bug_mock_vnode).

-export([start_vnode/1,
         get_index/1,
         ping/1,
         send_deferred/2,
         get_last_info/1,
         get_deferred_result/1,
         stop/1]).

-export([init/1,
         handle_command/3,
         handle_info/2,
         handle_exit/3,
         delete/1,
         terminate/2]).

-record(state, {index, last_info, deferred_result}).

-define(MASTER, bug_mock_vnode_master).

%% API

start_vnode(I) ->
    riak_core_vnode_master:start_vnode(I, ?MODULE).

get_index(Preflist) ->
    riak_core_vnode_master:sync_command(Preflist, get_index, ?MASTER).

ping(Preflist) ->
    riak_core_vnode_master:sync_command(Preflist, ping, ?MASTER).

send_deferred(Preflist, DelayMs) ->
    riak_core_vnode_master:sync_command(Preflist, {send_deferred, DelayMs}, ?MASTER).

get_last_info(Preflist) ->
    riak_core_vnode_master:sync_command(Preflist, get_last_info, ?MASTER).

get_deferred_result(Preflist) ->
    riak_core_vnode_master:sync_command(Preflist, get_deferred_result, ?MASTER).

stop(Preflist) ->
    riak_core_vnode_master:sync_command(Preflist, stop, ?MASTER).

%% Callbacks

init([Index]) ->
    {ok, #state{index = Index}}.

handle_command(get_index, _Sender, State) ->
    {reply, {ok, State#state.index}, State};
handle_command(ping, _Sender, State) ->
    {reply, pong, State};
handle_command({send_deferred, DelayMs}, _Sender, State) ->
    riak_core_vnode:send_command_after(DelayMs, deferred_cmd),
    {reply, ok, State};
handle_command(deferred_cmd, _Sender, State) ->
    {noreply, State#state{deferred_result = received}};
handle_command(get_deferred_result, _Sender, State) ->
    {reply, State#state.deferred_result, State};
handle_command(get_last_info, _Sender, State) ->
    {reply, State#state.last_info, State};
handle_command(stop, Sender, State) ->
    riak_core_vnode:reply(Sender, stopped),
    {stop, normal, State}.

handle_info(Info, State) ->
    {ok, State#state{last_info = Info}}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

delete({deleted, ModState}) ->
    {ok, ModState};
delete(ModState) ->
    {ok, ModState}.

terminate(_Reason, _State) ->
    ok.
