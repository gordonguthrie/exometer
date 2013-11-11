%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%%   This Source Code Form is subject to the terms of the Mozilla Public
%%   License, v. 2.0. If a copy of the MPL was not distributed with this
%%   file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% -------------------------------------------------------------------

%% @doc Custom reporting probe for Hosted Graphite.
%%
%% Collectd unix socket integration.
%% All data subscribed to by the plugin (through exosense_report:subscribe())
%% will be reported to collectd.
%% @end

%% We have to do this as a gen server since collectd expects periodical
%% metrics "refreshs", even if the values have not changed. We do this
%% through erlang:send_after() calls with the metrics / value update
%% to emit.
%%
%% Please note that exometer_report_collectd is still also a
%% exometer_report implementation.

-module(exometer_report_collectd).
-behaviour(exometer_report).
-behaviour(gen_server).

-export([exometer_init/1, 
	 exometer_report/4,
	 exometer_subscribe/3,
	 exometer_unsubscribe/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-include("exometer.hrl").

-define(CONNECT_TIMEOUT, 5000).
-define(RECONNECT_INTERVAL, 30). %% seconds
-define(READ_TIMEOUT, 5000).
-define(REFRESH_INTERVAL, 10). %% seconds

-record(st, {
	  hostname = undefined,
	  socket_path = undefined,
	  plugin_name = undefined,
	  plugin_instance = undefined,
	  refresh_interval = ?REFRESH_INTERVAL,
	  type_spec = undefined,
	  read_timeout = ?READ_TIMEOUT,
	  connect_timeout = ?CONNECT_TIMEOUT,
	  reconnect_interval = ?RECONNECT_INTERVAL,
	  socket = undefined}).

%% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).
-define(UNIX_EPOCH, 62167219200).

-include("log.hrl").

%% Probe callbacks
exometer_init(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,  Opts, []),
    {ok, undefined}.


exometer_report(Metric, DataPoint, Value, St) ->
    io:format("exometer_report(): ~p~n", [St]),
    ?SERVER ! { report_exometer, Metric, DataPoint, Value },
    { ok, St }.

exometer_subscribe(_Metric, _DataPoint, St) ->
    {ok, St }.

exometer_unsubscribe(Metric, DataPoint, St) ->
    %% Kill off any refresh timers that we may have handle_info( {
    %% refresh_metric, ...) will verify that the ets table has a key
    %% before it refreshes the metric in collectd and reschedules the
    %% next refresh operation.
    case ets:lookup(exometer_collectd, ets_key(Metric, DataPoint)) of
	[] -> ok;
	[{_, TRef}] -> 
	    io:format("Canceling old timer through unsubscribe~n"),
	    ets:delete(exometer_collectd, ets_key(Metric, DataPoint)),
	    erlang:cancel_timer(TRef)
    end,

    {ok, St}.

init(Opts) ->
    io:format("Exometer exometer Reporter: Opts: ~p~n", [Opts]),
    SockPath = get_opt(path, Opts),
    ConnectTimeout = get_opt(connect_timeout, Opts, ?CONNECT_TIMEOUT),
    ReconnectInterval = get_opt(reconnect_interval, Opts, ?RECONNECT_INTERVAL) * 1000,

    %% [ { metric, type }, ... ]
    ets:new(exometer_collectd, [ named_table, { keypos, 1}, public, set ]),

    %% Try to connect to collectd.
    case connect_collectd(SockPath, ConnectTimeout) of
	{ok, Sock} ->
	    { ok, 
	      #st{socket_path = SockPath,
		  reconnect_interval = ReconnectInterval,
		  hostname = get_opt(hostname, Opts, net_adm:localhost()),
		  plugin_name = get_opt(plugin_name, Opts, "exometer"),
		  plugin_instance = get_opt(plugin_instance, Opts, get_default_instance()),
		  socket = Sock,
		  read_timeout = get_opt(read_timeout, Opts, ?READ_TIMEOUT),
		  connect_timeout = ConnectTimeout,
		  refresh_interval = get_opt(refresh_interval, Opts, ?REFRESH_INTERVAL) * 1000,
		  type_spec = get_opt(type_spec, Opts, undefined)
		 } 
	    };
	{error, _} = Error ->
	    io:format("Exometer exometer connection failed; ~p. Retry in ~p~n", 
		      [Error, ReconnectInterval]),
	    reconnect_after(ReconnectInterval),
	    { ok, 
	      #st{socket_path = SockPath,
		  reconnect_interval = ReconnectInterval,
		  hostname = get_opt(hostname, Opts, net_adm:localhost()),
		  plugin_name = get_opt(plugin_name, Opts, "exometer"),
		  plugin_instance = get_opt(plugin_instance, Opts, get_default_instance()),
		  socket = undefined,
		  read_timeout = get_opt(read_timeout, Opts, ?READ_TIMEOUT),
		  connect_timeout = ConnectTimeout,
		  refresh_interval = get_opt(refresh_interval, Opts, 10) * 1000,
		  type_spec = get_opt(type_spec, Opts, undefined)
		 } 
	    }
    end.


handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info({report_exometer, _Metric, _DataPoint, _Value}, St) when St#st.socket =:= undefined ->
    io:format("Report metric: No connection. Value lost~n"),
    {noreply, St};

%% Invoked through the remote_exometer() function to
%% send out an update.
handle_info({report_exometer, Metric, DataPoint, Value}, St) ->
    io:format("Report metric ~p_~p = ~p~n", [ Metric, DataPoint, Value ]),
    
    %% Cancel and delete any refresh timer, if it exists
    case ets:lookup(exometer_collectd, ets_key(Metric, DataPoint)) of
	[] -> ok;
	[{_, TRef}] -> 
	    %% We don't need to delete the old ets entry
	    %% since it will be replaced by ets:insert()
	    %% in report_exometer_()
	    io:format("Canceling old timer~n"),
	    erlang:cancel_timer(TRef)
		
    end,
	
    %% Report the value and setup a new refresh timer.
    { noreply, report_exometer_(Metric, DataPoint, Value, St)};


handle_info({refresh_metric, Metric, DataPoint, Value}, St) ->
    %% Make sure that we still have an entry in the ets table.
    %% If not, exometer_unsubscribe() has been called to remove
    %% the entry, and we should do nothing.
    case ets:lookup(exometer_collectd, ets_key(Metric, DataPoint)) of
	[] -> 
	    io:format("refresh_metric(~p, ~p): No longer subscribed~n", [Metric, DataPoint]),
	    { noreply, St };
	[{_, _TRef}] -> 
	    io:format("Refreshing metric ~p_~p = ~p~n", [ Metric, DataPoint, Value ]),
	    { noreply, report_exometer_(Metric, DataPoint, Value, St)}
    end;


handle_info(reconnect, St) ->
    io:format("Reconnecting~n"),
    case connect_collectd(St) of
	{ ok, NSt } -> 
	    { noreply, NSt};

	Err  -> 
	    io:format("Could not connect: ~p~n", [ Err ]),
	    reconnect_after(St#st.reconnect_interval),
	    { noreply, St }
    end;

handle_info(_Msg, State) ->
    {noreply, State}.



terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


report_exometer_(Metric, DataPoint, Value, #st{
				     hostname = HostName,
				     plugin_name = PluginName,
				     plugin_instance = PluginInstance,
				     socket = Sock,
				     read_timeout = TOut, 
				     refresh_interval = RefreshInterval,
				     type_spec = TypeSpec} = St) ->
    io:format("report~n"),

    Type = find_type(TypeSpec, name(Metric, DataPoint)),
    Request = "PUTVAL " ++ HostName ++ "/" ++  
	PluginName ++ "-" ++ PluginInstance ++ "/" ++
	Type ++ "-" ++ name(Metric, DataPoint) ++ " " ++
	timestamp() ++ ":" ++ value(Value) ++ [$\n],

    
    io:format("L(~p) = ~p~n", [Value, Request]),

    case catch afunix:send(Sock, list_to_binary(Request)) of
	ok ->
	    case afunix:recv(Sock, 0, TOut) of
		{ ok, Bin } ->
		    %% Parse the reply
		    case parse_reply(Request, Bin, St) of
			%% Replyis ok.
			%% Ensure that we have periodical refreshs of this value.
			{ ok, St } ->
			    io:format("Setting up refresh~n"),
			    setup_refresh(RefreshInterval, Metric, DataPoint, Value),
			    St;
			%% Something went wrong with reply. Do not refresh
			_ -> St
		    end;
		
		_ -> 
		    %% We failed to receive data, close and setup later reconnect
		    io:format("Failed to receive. Will reconnect in ~p~n", [ St#st.reconnect_interval ]),
		    reconnect_after(Sock, St#st.reconnect_interval),
		    St#st { socket = undefined }
	    end;
		
	_ ->
	    %% We failed to receive data, close and setup later reconnect
	    io:format("Failed to send. Will reconnect in ~p~n", [ St#st.reconnect_interval ]),
	    reconnect_after(Sock, St#st.reconnect_interval),
	    St#st { socket = undefined }
    end.


ets_key(Metric, DataPoint) ->
    Metric ++ [ DataPoint ].

%% Add metric and datapoint within metric
name(Metric, DataPoint) -> 
    metric_to_string(Metric) ++ "_" ++ atom_to_list(DataPoint).

metric_to_string([Final]) ->
    metric_elem_to_list(Final);

metric_to_string([H | T]) ->
    metric_elem_to_list(H) ++ "_" ++ metric_to_string(T).

metric_elem_to_list(E) when is_atom(E) ->
    atom_to_list(E);

metric_elem_to_list(E) when is_list(E) ->
    E;

metric_elem_to_list(E) when is_integer(E) ->
    integer_to_list(E).



%% Add value, int or float, converted to list
value(V) when is_integer(V) -> integer_to_list(V);
value(V) when is_float(V)   -> float_to_list(V);
value(_) -> "0".

timestamp() ->
    integer_to_list(unix_time()).

connect_collectd(St) ->
    case connect_collectd(St#st.socket_path, St#st.connect_timeout) of
	{ ok, Sock } -> { ok, St#st { socket = Sock }};
	Err -> Err
    end.
	    

connect_collectd(SocketPath, ConnectTimeout) ->
    afunix:connect(SocketPath, [{active, false}, {mode, binary}], ConnectTimeout).

unix_time() ->
    datetime_to_unix_time(erlang:universaltime()).

datetime_to_unix_time({{_,_,_},{_,_,_}} = DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) - ?UNIX_EPOCH.

get_opt(K, Opts) ->
    case lists:keyfind(K, 1, Opts) of
	{_, V} -> V;
	false  -> error({required, K})
    end.

get_opt(K, Opts, Default) ->
    case lists:keyfind(K, 1, Opts) of
	{_, V} -> V;
	false  ->
	    if is_function(Default,0) -> Default();
	       true -> Default
	    end
    end.

get_default_instance() ->
    FullName = atom_to_list(node()),
    case  string:rchr(FullName, $@) of
	0 -> FullName;
	Ind -> string:substr(FullName, 1, Ind - 1)
    end.

%% Parse a line returned by collectd.
%% It has the format 
parse_reply(Request, Reply, St) ->
    case parse_reply(Reply, []) of 
	{0, _} ->
	    {ok, St};

	{-1, _} -> 
	    ?error("Failed to log ~p: ~p~n", [Request, Reply]), 
	    { error, St };

	{_, _} ->
	    ?info("Got unexpected (and ignored) reply for: ~p: ~p~n", [Request, Reply]), 
	    { unsupported,  St }
	end.

		

%% Parse the space after the integer at line beginning.
%% The remainder will always have at least a newline.
parse_reply(<< $\s, Rem/binary >>, RetVal) ->
    %% Reverse the list containing the integer (in ascii format),
    %% and trigger the parsing of the remaining
    Text = binary:part(Rem, 0, size(Rem) - 1),

    %% Reverse the retval and convert to integer.
    %% Return together with text.
    { list_to_integer(lists:reverse(RetVal)), Text };

%% Parse the first part of RetVal, which is the integer at the beginning
%% of the line.
parse_reply(<< C:1/integer-unit:8,Rem/binary >>, RetVal) ->
    parse_reply(Rem, [ C | RetVal ]).

find_type(_TypeSpec, _Name) ->
    "gauge". %% FIXME

reconnect_after(Socket, ReconnectInterval) ->
    %% Close socket if open
    if Socket =/= undefined -> afunix:close(Socket);
	true -> true
    end,
    reconnect_after(ReconnectInterval).

reconnect_after(ReconnectInterval) ->
   erlang:send_after(ReconnectInterval, self(), reconnect).

setup_refresh(RefreshInterval, Metric, DataPoint, Value) ->
    io:format("Will refresh after ~p~n", [ RefreshInterval ]),
    TRef = erlang:send_after(RefreshInterval, self(), 
			     { refresh_metric, Metric, DataPoint, Value}),

    ets:insert(exometer_collectd, { ets_key(Metric, DataPoint), TRef}),
    ok.