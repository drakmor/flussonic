%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2012 Max Lapshin
%%% @doc        flussonic_app
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlmedia is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlmedia is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlmedia.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(flussonic_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-export([read_config/0, load_config/0]).
% -export([current_cowboy_port/1]).
-include("log.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->  
  {ok, Pid} = flussonic_sup:start_link(),
  {ok, Pid}.
  
  
stop(_State) ->
  ok.




% current_cowboy_port(Name) ->
%   try current_cowboy_port0(Name) of
%     Result -> Result
%   catch
%     _:_ -> undefined
%   end.
      

% current_cowboy_port0(Name) ->
%   {{cowboy_listener_sup,Name},Pid1,_,_} = lists:keyfind({cowboy_listener_sup,Name}, 1, supervisor:which_children(cowboy_sup)),
%   [state, _, _, ChildSpec |_] = tuple_to_list(ems_debug:get_state(Pid1)),
%   [child, _Pid2, cowboy_acceptors_sup, {_M,_F,A} |_] = tuple_to_list(lists:keyfind(cowboy_acceptors_sup, 3, ChildSpec)),
%   [_Count, cowboy_tcp_transport, Opts|_] = A,
%   proplists:get_value(port, Opts).


read_config() ->
  case flu_config:load_config() of
    {ok, Env1, ConfigPath} ->
      flu_config:set_config(Env1),
      application:load(flussonic),
      Vsn = case application:get_key(flussonic, vsn) of
        {ok, V} -> V;
        undefined -> undefined
      end,
      case application:get_env(flussonic, config) of
        undefined -> error_logger:info_msg("Loading config for version ~s from ~s", [Vsn, ConfigPath]);
        {ok, _} -> ok
      end,
      flu_config:get_config();
    {error, enoent} ->
      error_logger:error_msg("Can't find flussonic.conf in any folder~n"),
      throw(invalid_config);
    {error, {Line,erl_parse,Message}} ->
      error_logger:error_msg("flussonic.conf has invalid syntax on line ~B. Error is: ~s, but is may be earlier~n", [Line,Message]),
      throw(invalid_config);
    {error, Else} ->
      error_logger:error_msg("Can't open flussonic.conf: ~p~n", [Else]),
      throw(invalid_config)
  end.

load_config() ->
  OldConfig = flu_config:get_config(),
  Env = read_config(),
  LogLevel = proplists:get_value(loglevel, Env, info),
  lager:set_loglevel(lager_console_backend, LogLevel),
  lager:set_loglevel(lager_file_backend, LogLevel),

  flu:start_webserver(Env),

  
  case proplists:get_value(rtmp, Env) of
    undefined -> rtmp_socket:stop_server(rtmp_listener1);
    RTMPPort ->
	  	lager:notice("Start RTMP server at port ~B", [RTMPPort]),
  	  rtmp_socket:start_server(RTMPPort, rtmp_listener1, flu_rtmp)
  end,
  case proplists:get_value(rtsp, Env) of
	  undefined -> rtsp:stop_server(rtsp_listener1);
	  RTSPPort ->
	    lager:notice("Start RTSP server at port ~B", [RTSPPort]),
	    rtsp:start_server(RTSPPort, rtsp_listener1, flu_rtsp)
	end,

  [begin
    (catch Plugin:module_info()),
    case erlang:function_exported(Plugin, start, 1) of
      true -> Plugin:start(Options);
      false -> ok
    end
  end || {plugin, Plugin, Options} <- flu_config:get_config()],

  flu_event:start_handlers(),

  [catch flu_stream:update_options(Stream, [{url,URL}|StreamOpts]) || {stream, Stream, URL, StreamOpts} <- Env],
  ConfigStreams = [Stream || {stream, Stream, _URL, _StreamOpts} <- Env],
  OldStreams = [Stream || {stream, Stream, _, _} <- OldConfig, not lists:member(Stream, ConfigStreams)],
  [catch flu_stream:non_static(Name) || {Name, _} <- flu_stream:list(), not lists:member(Name, ConfigStreams)],
  [catch flu_stream:stop(Name) || {Name, _} <- flu_stream:list(), lists:member(Name, OldStreams)],


  ok.


