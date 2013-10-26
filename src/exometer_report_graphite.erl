%% @doc Custom reporting probe for Hosted Graphite.
%%
%% This probe periodically samples a user-defined set of metrics, and
%% reports them to Hosted Graphite (https://hostedgraphite.com)
%% @end
-module(exometer_report_graphite).
-behaviour(exometer_report).

-export([init/1, report/4]).

-include("exometer.hrl").

-define(HOST, "carbon.hostedgraphite.com").
-define(PORT, 2003).
-define(CONNECT_TIMEOUT, 5000).

-record(st, {
	  name,
	  namespace = [],
	  prefix = [],
	  api_key = "",
	  socket = undefined,
	  mode}).

%% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).
-define(UNIX_EPOCH, 62167219200).

-include("log.hrl").

%% Probe callbacks

init(Opts) ->
    ?info("Exometer Graphite Reporter; Opts: ~p~n", [Opts]),
    Mode = get_opt(mode, Opts, normal),
    API_key = get_opt(api_key, Opts),
    Prefix = get_opt(prefix, Opts, []),

    case gen_tcp:connect(?HOST, ?PORT,  [{mode, list}], ?CONNECT_TIMEOUT) of
	{ok, Sock} ->
	    {ok, #st{prefix = Prefix,
		     api_key = API_key,
		     socket = Sock,
		     mode = Mode}};
	{error, _} = Error ->
	    Error
    end.


report(Probe, DataPoint, Value, #st{socket = Sock,
				    api_key = APIKey,
				    prefix = Prefix} = St) ->
    Line = [prefix(Prefix, APIKey), ".", name(Probe, DataPoint), " ",
	    value(Value), " ", timestamp(), $\n],
    io:fwrite("L = ~s~n", [Line]),
    case gen_tcp:send(Sock, Line) of
	ok ->
	    {ok, St};
	_ ->
	    reconnect(St)
    end.

%% Add prefix, if non-empty.
prefix([]     , APIKey) -> APIKey;
prefix(Prefix , APIKey) -> [APIKey, ".", Prefix].

%% Add probe and datapoint within probe
name(Probe, DataPoint) -> [Probe, ".", atom_to_list(DataPoint)].

%% Add value, int or float, converted to list
value(V) when is_integer(V) -> integer_to_list(V);
value(V) when is_float(V)   -> float_to_list(V);
value(_) -> 0.

timestamp() ->
    integer_to_list(unix_time()).


reconnect(St) ->
    case gen_tcp:connect(?HOST, ?PORT,  [{mode, list}], ?CONNECT_TIMEOUT) of
	{ok, Sock} ->
	    {ok, St#st{socket = Sock}};
	{error, _} = Error ->
	    Error
    end.

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