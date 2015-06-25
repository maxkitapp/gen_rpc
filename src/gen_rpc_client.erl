%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
%%% Original concept inspired and some code copied from
%%% https://erlangcentral.org/wiki/index.php?title=Building_a_Non-blocking_TCP_server_using_OTP_principles

-module(gen_rpc_client).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Behaviour
-behaviour(gen_server).

%%% Include this library's name macro
-include("include/app.hrl").

%%% Local state
-record(state, {socket :: port(),
        node :: atom(),
        send_timeout :: non_neg_integer(),
        receive_timeout :: non_neg_integer(),
        inactivity_timeout :: non_neg_integer() | infinity}).

%%% Default TCP options
-define(DEFAULT_TCP_OPTS, [binary, {packet,4},
        {nodelay,true}, % Send our requests immediately
        {send_timeout_close,true}, % When the socket times out, close the connection
        {delay_send,true}, % Scheduler should favor big batch requests
        {linger,{true,2}}, % Allow the socket to flush outgoing data for 2" before closing it - useful for casts
        {reuseaddr,true}, % Reuse local port numbers
        {keepalive,true}, % Keep our channel open
        {tos,72}, % Deliver immediately
        {active,false}]). % Retrieve data from socket upon request

%%% Supervisor functions
-export([start_link/1, stop/1]).

%%% FSM functions
-export([call/3, call/4, call/5, call/6, cast/3, cast/4, cast/5]).

%%% Behaviour callbacks
-export([init/1, handle_call/3, handle_cast/2,
        handle_info/2, terminate/2, code_change/3]).

%%% Process exports
-export([call_worker/3]).

%%% ===================================================
%%% Supervisor functions
%%% ===================================================
start_link(Node) when is_atom(Node) ->
    %% Naming our gen_server as the node we're calling as it is extremely efficent:
    %% We'll never deplete atoms because all connected node names are already atoms in this VM
    gen_server:start_link({local,Node}, ?MODULE, {Node}, [{spawn_opt, [{priority, high}]}]).

stop(Node) when is_atom(Node) ->
    gen_server:call(Node, stop).

%%% ===================================================
%%% Server functions
%%% ===================================================
%% Simple server call with no args and default timeout values
call(Node, M, F) when is_atom(Node), is_atom(M), is_atom(F) ->
    call(Node, M, F, [], undefined, undefined).

%% Simple server call with args and default timeout values
call(Node, M, F, A) when is_atom(Node), is_atom(M), is_atom(F), is_list(A) ->
    call(Node, M, F, A, undefined, undefined).

%% Simple server call with custom receive timeout value
call(Node, M, F, A, RecvTO) when is_atom(Node), is_atom(M), is_atom(F), is_list(A),
                                 is_integer(RecvTO) orelse RecvTO =:= infinity ->
    call(Node, M, F, A, RecvTO, undefined).

%% Simple server call with custom receive and send timeout values
%% This is the function that all of the above call
call(Node, M, F, A, RecvTO, SendTO) when is_atom(Node), is_atom(M), is_atom(F), is_list(A),
                                         RecvTO =:= undefined orelse is_integer(RecvTO) orelse RecvTO =:= infinity,
                                         SendTO =:= undefined orelse is_integer(SendTO) orelse SendTO =:= infinity ->
    case whereis(Node) of
        undefined ->
            ok = lager:info("function=call event=client_process_not_found server_node=\"~s\" action=spawning_client", [Node]),
            case gen_rpc_dispatcher:start_client(Node) of
                {ok, NewPid} ->
                    %% We take care of CALL inside the gen_server
                    %% This is not resilient enough if the caller's mailbox is full
                    %% but it's good enough for now
                    gen_server:call(NewPid, {{call,M,F,A},RecvTO,SendTO}, infinity);
                {error, Reason} ->
                    Reason
            end;
        Pid ->
            ok = lager:debug("function=call event=client_process_found pid=\"~p\" server_node=\"~s\"", [Pid, Node]),
            gen_server:call(Pid, {{call,M,F,A},RecvTO,SendTO}, infinity)
    end.

%% Simple server cast with no args and default timeout values
cast(Node, M, F) when is_atom(Node), is_atom(M), is_atom(F) ->
    cast(Node, M, F, [], undefined).

%% Simple server cast with args and default timeout values
cast(Node, M, F, A) when is_atom(Node), is_atom(M), is_atom(F), is_list(A) ->
    cast(Node, M, F, A, undefined).

%% Simple server cast with custom send timeout value
%% This is the function that all of the above casts call
cast(Node, M, F, A, SendTO) when is_atom(Node), is_atom(M), is_atom(F), is_list(A),
                                 SendTO =:= undefined orelse is_integer(SendTO) orelse SendTO =:= infinity ->
    %% Naming our gen_server as the node we're calling as it is extremely efficent:
    %% We'll never deplete atoms because all connected node names are already atoms in this VM
    case whereis(Node) of
        undefined ->
            ok = lager:info("function=cast event=client_process_not_found server_node=\"~s\" action=spawning_client", [Node]),
            case gen_rpc_dispatcher:start_client(Node) of
                {ok, NewPid} ->
                    %% We take care of CALL inside the gen_server
                    %% This is not resilient enough if the caller's mailbox is full
                    %% but it's good enough for now
                    gen_server:call(NewPid, {{cast,M,F,A},SendTO});
                {error, Reason} ->
                    Reason
            end;
        Pid ->
            ok = lager:debug("function=cast event=client_process_found pid=\"~p\" server_node=\"~s\"", [Pid, Node]),
            gen_server:call(Pid, {{cast,M,F,A},SendTO})
    end.


%%% ===================================================
%%% Behaviour callbacks
%%% ===================================================
init({Node}) ->
    process_flag(trap_exit, true),
    %% Extract application-specific settings
    Settings = application:get_all_env(?APP),
    {connect_timeout, ConnTO} = lists:keyfind(connect_timeout, 1, Settings),
    {send_timeout, SendTO} = lists:keyfind(send_timeout, 1, Settings),
    {receive_timeout, RecvTO} = lists:keyfind(receive_timeout, 1, Settings),
    {client_inactivity_timeout, TTL} = lists:keyfind(client_inactivity_timeout, 1, Settings),
    %% Perform an in-band RPC call to the remote node
    %% asking it to launch a listener for us and return us
    %% the port that has been allocated for us
    ok = lager:info("function=init event=initializing_client server_node=\"~s\" connect_timeout=~B send_timeout=~B receive_timeout=~B inactivity_timeout=~p",
                    [Node, ConnTO, SendTO, RecvTO, TTL]),
    case rpc:call(Node, gen_rpc_server_sup, start_child, [node()], ConnTO) of
        {ok, Port} ->
            %% Fetching the IP ourselves, since the remote node
            %% does not have a straightforward way of returning
            %% the proper remote IP
            Address = get_remote_node_ip(Node),
            ok = lager:debug("function=init event=remote_server_started_successfully server_node=\"~s\" server_ip=\"~p:~B\"",
                             [Node, Address, Port]),
            case gen_tcp:connect(Address, Port, ?DEFAULT_TCP_OPTS, ConnTO) of
                {ok, Socket} ->
                    ok = lager:debug("function=init event=connecting_to_server server_node=\"~s\" server_ip=\"~p:~B\" result=success",
                                     [Node, Address, Port]),
                    {ok, #state{socket=Socket,node=Node,send_timeout=SendTO,receive_timeout=RecvTO,inactivity_timeout=TTL}, TTL};
                {error, Reason} ->
                    ok = lager:error("function=init event=connecting_to_server server_node=\"~s\" server_ip=\"~s:~B\" result=failure reason=\"~p\"",
                                     [Node, Address, Port, Reason]),
                    {stop, {badtcp,Reason}}
            end;
        {badrpc, Reason} ->
            {stop, {badrpc, Reason}}
    end.

%% This is the actual CALL handler
handle_call({{call,_M,_F,_A} = PacketTuple, URecvTO, USendTO}, Caller, #state{socket=Socket,node=Node} = State) ->
    {RecvTO, SendTO} = merge_timeout_values(State#state.receive_timeout, URecvTO, State#state.send_timeout, USendTO),
    Ref = erlang:make_ref(),
    %% Spawn the worker that will wait for the server's reply
    WorkerPid = erlang:spawn(?MODULE, call_worker, [Ref, Caller, RecvTO]),
    %% Let the server know of the responsible process
    Packet = erlang:term_to_binary({node(), WorkerPid, Ref, PacketTuple}),
    ok = lager:debug("function=handle_call message=call event=constructing_call_term socket=\"~p\" call_reference=\"~p\"",
                     [Socket, Ref]),
    %% Since call can fail because of a timed out connection without gen_rpc knowing it,
    %% we have to make sure the remote node is reachable somehow before we send data. net_kernel:connect does that
    case net_adm:ping(Node) of
        pong ->
            case gen_tcp:send(Socket, Packet) of
                {error, timeout} ->
                    ok = lager:error("function=handle_call message=call event=transmission_failed socket=\"~p\" call_reference=\"~p\" reason=\"timeout\"",
                                     [Socket, Ref]),
                    %% Reply will be handled from the worker
                    {stop, {badtcp,send_timeout}, State};
                {error, Reason} ->
                    ok = lager:error("function=handle_call message=call event=transmission_failed socket=\"~p\" call_reference=\"~p\" reason=\"~p\"",
                                     [Socket, Ref, Reason]),
                    %% Reply will be handled from the worker
                    {stop, {badtcp,Reason}, State};
                ok ->
                    ok = lager:debug("function=handle_call message=call event=transmission_succeeded socket=\"~p\" call_reference=\"~p\"",
                                     [Socket, Ref]),
                    %% We need to enable the socket and perform the call only if the call succeeds
                    ok = inet:setopts(Socket, [{active, once}, {send_timeout, SendTO}]),
                    %% Reply will be handled from the worker
                    {noreply, State, State#state.inactivity_timeout}
            end;
        pang ->
            ok = lager:error("function=handle_call message=call event=node_down socket=\"~p\" call_reference=\"~p\"",
                             [Socket, Ref]),
            {stop, {badrpc,nodedown}, State}
    end;
%% This is the actual CAST handler
handle_call({{cast,_M,_F,_A} = PacketTuple, USendTO}, _Caller, #state{socket=Socket,node=Node} = State) ->
    {_RecvTO, SendTO} = merge_timeout_values(undefined, undefined, State#state.send_timeout, USendTO),
    %% Cast requests do not need a reference
    Packet = erlang:term_to_binary({node(), PacketTuple}),
    ok = lager:debug("function=handle_cast message=cast event=constructing_cast_term socket=\"~p\"", [Socket]),
    %% Set the send timeout and do not run in active mode - we're a cast!
    ok = inet:setopts(Socket, [{send_timeout, SendTO}]),
    %% Since cast can fail because of a timed out connection without gen_rpc knowing it,
    %% we have to make sure the remote node is reachable somehow before we send data. net_kernel:connect does that
    case net_adm:ping(Node) of
        pong ->
            case gen_tcp:send(Socket, Packet) of
                {error, timeout} ->
                    %% Terminate will handle closing the socket
                    ok = lager:error("function=handle_cast message=cast event=transmission_failed socket=\"~p\" reason=\"timeout\"", [Socket]),
                    {stop, {badtcp,send_timeout}, {badtcp,send_timeout}, State};
                {error, Reason} ->
                    ok = lager:error("function=handle_cast message=cast event=transmission_failed socket=\"~p\" reason=\"~p\"", [Socket, Reason]),
                    {stop, {badtcp,Reason}, {badtcp,Reason}, State};
                ok ->
                    ok = lager:debug("function=handle_cast message=cast event=transmission_succeeded socket=\"~p\"", [Socket]),
                    {reply, ok, State, State#state.inactivity_timeout}
            end;
        pang ->
            ok = lager:error("function=handle_cast message=cast event=node_down socket=\"~p\"", [Socket]),
            {stop, {badrpc,nodedown}, {badrpc,nodedown}, State}
    end;
%% Gracefully terminate
handle_call(stop, _Caller, State) ->
    ok = lager:debug("function=handle_call event=stopping_client socket=\"~p\"", [State#state.socket]),
    {stop, normal, ok, State};

%% Catch-all for calls - die if we get a message we don't expect
handle_call(Msg, _Caller, State) ->
    ok = lager:critical("function=handle_call event=uknown_call_received socket=\"~p\" message=\"~p\" action=stopping", [State#state.socket, Msg]),
    {stop, {unknown_call, Msg}, State}.

%% Catch-all for casts - die if we get a message we don't expect
handle_cast(Msg, State) ->
    ok = lager:critical("function=handle_call event=uknown_cast_received socket=\"~p\" message=\"~p\" action=stopping", [State#state.socket, Msg]),
    {stop, {unknown_cast, Msg}, State}.

%% Handle any TCP packet coming in
handle_info({tcp,Socket,Data}, #state{socket=Socket} = State) ->
    _Reply = try erlang:binary_to_term(Data) of
        {WorkerPid, Ref, Reply} ->
            case erlang:is_process_alive(WorkerPid) of
                true ->
                    ok = lager:debug("function=handle_info message=tcp event=reply_received call_reference=\"~p\" worker_pid=\"~p\" action=sending_to_worker",
                                     [Ref, WorkerPid]),
                    WorkerPid ! {reply,Ref,Reply};
                false ->
                    ok = lager:notice("function=handle_info message=tcp event=reply_received_with_dead_worker call_reference=\"~p\" worker_pid=\"~p\"",
                                      [Ref, WorkerPid])
            end;
        OtherData ->
            ok = lager:error("function=handle_info message=tcp event=erroneous_reply_received socket=\"~p\" data=\"~p\" action=ignoring",
                             [Socket, OtherData])
    catch
        error:badarg ->
            ok = lager:error("function=handle_info message=tcp event=corrupt_data_received socket=\"~p\" action=ignoring", [Socket])
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State, State#state.inactivity_timeout};

handle_info({tcp_closed, Socket}, #state{socket=Socket} = State) ->
    ok = lager:notice("function=handle_info message=tcp_closed event=tcp_socket_closed socket=\"~p\" action=stopping", [Socket]),
    {stop, normal, State};

handle_info({tcp_error, Socket, Reason}, #state{socket=Socket} = State) ->
    ok = lager:notice("function=handle_info message=tcp_error event=tcp_socket_error socket=\"~p\" reason=\"~p\" action=stopping", [Socket, Reason]),
    {stop, normal, State};

%% Handle the inactivity timeout gracefully
handle_info(timeout, State) ->
    ok = lager:info("function=handle_info message=timeout event=client_inactivity_timeout socket=\"~p\" action=stopping", [State#state.socket]),
    {stop, normal, State};

%% Catch-all for info - our protocol is strict so die!
handle_info(Msg, State) ->
    ok = lager:critical("function=handle_info event=uknown_message_received socket=\"~p\" message=\"~p\" action=stopping", [State#state.socket, Msg]),
    {stop, {unknown_info, Msg}, State}.

%% Stub functions
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket=Socket}) ->
    ok = lager:debug("function=terminate socket=\"~p\"", [Socket]),
    (catch gen_tcp:close(Socket)),
    _Pid = erlang:spawn(gen_rpc_client_sup, stop_child, [self()]),
    ok.

%%% ===================================================
%%% Private functions
%%% ===================================================
%% For loopback communication and performance testing
get_remote_node_ip(Node) when Node =:= node() ->
    {127,0,0,1};
get_remote_node_ip(Node) ->
    {ok, NodeInfo} = net_kernel:node_info(Node),
    {address, AddressInfo} = lists:keyfind(address, 1, NodeInfo),
    {net_address, {Ip, _Port}, _Name, _Proto, _Channel} = AddressInfo,
    ok = lager:debug("function=get_remote_node_ip node=\"~s\" ip_address=\"~p\"", [Node, Ip]),
    Ip.

%% This function is a process launched by the gen_server, waiting to receive a
%% reply from the TCP channel via the gen_server
call_worker(Ref, Caller, Timeout) when is_tuple(Caller), is_reference(Ref) ->
    receive
        {reply,Ref,Reply} ->
            ok = lager:debug("function=call_worker event=reply_received call_reference=\"~p\" reply=\"~p\"",
                             [Ref, Reply]),
            _Ign = gen_server:reply(Caller, Reply),
            exit(normal),
            ok;
        Else ->
            ok = lager:error("function=call_worker event=invalid_message_received call_reference=\"~p\" message=\"~p\"",
                             [Ref, Else]),
            _Ign = gen_server:reply(Caller, {badrpc, invalid_message_received}),
            exit({error, invalid_message_received})
    after
        Timeout ->
            ok = lager:notice("function=call_worker event=call_timeout call_reference=\"~p\"", [Ref]),
            _Ign = gen_server:reply(Caller, {badrpc, timeout}),
            exit({error, timeout})
    end.

%% Merging user-define timeout values with state timeout values
merge_timeout_values(SRecvTO, undefined, SSendTO, undefined) ->
    {SRecvTO, SSendTO};
merge_timeout_values(_SRecvTO, URecvTO, SSendTO, undefined) ->
    {URecvTO, SSendTO};
merge_timeout_values(SRecvTO, undefined, _SSendTO, USendTO) ->
    {SRecvTO, USendTO};
merge_timeout_values(_SRecvTO, URecvTO, _SSendTO, USendTO) ->
    {URecvTO, USendTO}.
