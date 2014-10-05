%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2012 Max Lapshin
%%% @doc        stream
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
-module(flu_stream).
-author('Max Lapshin <max@maxidoors.ru>').
-behaviour(gen_server).
-include("log.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").
-include("flu_stream.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/2]).
-export([media_info/1]).

-export([hds_manifest/1, hds_manifest/2, hds_fragment/2, bootstrap/1]).
-export([hds_manifest/3, rewrite_manifest/2]).
-export([hls_playlist/1, hls_playlist/2, hls_segment/3, hls_key/2, preview_jpeg/3]).

-export([subscribe/2, subscribe/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([after_terminate/2]).


% Helpers callbacks
-export([start_helper/3, stop_helper/2, find_helper/2]).

-export([notify_webhook/2]).

-export([autostart/1, restart/1, stop/1]).
-export([autostart/2, list/0, json_list/0]).

-export([pass_message/2, find/1]).
-export([non_static/1, static/1, update_options/2]).
-export([set_source/2]).

-export([send_frame/2]).

-define(RETRY_LIMIT, 10).
-define(TIMEOUT, 70000).
-define(SOURCE_TIMEOUT, 20000).



-record(helper, {
  id,
  pid,
  mfa
}).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%
%  Query stream list
%

list() ->
  lists:sort([{Name, stream_info(Name, Attrs)} || {Name, Attrs} <- gen_tracker:list(flu_streams)]).

json_list() ->
  RTMP = case proplists:get_value(rtmp, flu_config:get_config()) of
    undefined -> [];
    RTMP_ -> [{rtmp,RTMP_}]
  end,
  Streams = [ RTMP ++ [{name,Name}|parse_attr(Attr)] || {Name,Attr} <- list()],
  [{streams,Streams},{event,'stream.list'}].

white_keys() ->
  [dvr, hls, hds, last_dts, lifetime, name, type, ts_delay, client_count, play_prefix, retry_count,
  bytes_in, bytes_out, bitrate].

parse_attr(Attr) ->
  [{K,V} || {K,V} <- Attr, (is_binary(V) orelse is_number(V) orelse V == true orelse V == false) andalso lists:member(K,white_keys())].


stream_info(_Name, Attrs) ->
  filter_list(add_ts_delay(Attrs)).

filter_list(Attrs) ->
  [{K,V} || {K,V} <- Attrs, lists:member(K,white_keys())].

find(Pid) when is_pid(Pid) -> {ok, Pid};
find(Name) when is_list(Name) -> find(list_to_binary(Name));
find(Name) -> gen_tracker:find(flu_streams, Name).

  
add_ts_delay(Attrs) ->
  Now = os:timestamp(),
  Attr1 = case proplists:get_value(last_dts_at, Attrs) of
    undefined -> Attrs;
    LastDTSAt -> [{ts_delay,timer:now_diff(Now, LastDTSAt) div 1000}|Attrs]
  end,
  Attr2 = case proplists:get_value(last_access_at, Attr1) of
    undefined -> Attr1;
    LastAccessAt -> [{client_delay,timer:now_diff(Now, LastAccessAt) div 1000}|Attr1]
  end,
  Attr2.





%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%
%  Helpers API


start_helper(Stream, Id, {M,F,A} = MFA) when is_binary(Stream) ->
  Self = self(),
  case gen_tracker:find(flu_streams, Stream) of
    {ok, Self} ->
      case lists:keyfind(Id,#helper.id,get(helpers)) of
        #helper{pid = Pid} -> {ok, Pid};
        false ->
          {ok, Pid} = erlang:apply(M,F,A),
          Helper = #helper{id = Id, pid = Pid, mfa = MFA},
          put(helpers, [Helper|get(helpers)]),
          {ok, Pid}
      end;
    {ok, Pid} ->
      case gen_server:call(Pid, {find_helper, Id}) of
        {ok, Helper} -> {ok, Helper};
        undefined -> gen_server:call(Pid, {start_helper, Id, {M,F,A}})
      end;
    undefined ->
      {error, no_stream}
  end.





stop_helper(Stream, Id) when is_binary(Stream) ->
  Self = self(),
  case gen_tracker:find(flu_streams, Stream) of
    {ok, Self} ->      
      case lists:keytake(Id, #helper.id, get(helpers)) of
        {value, #helper{pid = Pid}, Helpers1} ->
          erlang:exit(Pid, shutdown),
          unlink(Pid),
          receive {'EXIT', Pid, _} -> ok after 0 -> ok end,
          erlang:monitor(process, Pid),
          receive
            {'DOWN', _, _, Pid, _} -> ok
          after
            500 -> 
              erlang:exit(Pid,kill),
              receive
                {'DOWN', _, _, Pid, _} -> ok
              end
          end,
          put(helpers, Helpers1),
          ok;
        false ->
          {error, no_helper}
      end;
    {ok, Pid} -> gen_server:call(Pid, {delete_child, Id});
    undefined -> {error, no_stream}
  end.




find_helper(Stream, Id) ->
  Self = self(),
  case gen_tracker:find(flu_streams, Stream) of
    {ok, Self} ->
      case lists:keyfind(Id, #helper.id, get(helpers)) of
        #helper{pid = Pid} -> {ok, Pid};
        false -> undefined
      end;
    {ok, Pid} ->
      gen_server:call(Pid, {find_helper, Id});
    undefined ->
      {error, no_stream}
  end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%
%  Lookup, autostart stream


autostart(Stream) ->
  case lookup_in_config(Stream, flu_config:get_config()) of
    undefined -> find(Stream);
    {ok, Stream1, Options} -> autostart(Stream1, Options)
  end.


restart(Name) ->
  case find(Name) of
    {ok, Pid} ->
      erlang:monitor(process,Pid),
      erlang:exit(Pid, kill),
      receive
        {'DOWN',_,_,Pid,_} -> ok
      after 
        1000 -> {error,failed}
      end;
    _ ->
      {error, unknown}
  end.


stop(Name) ->
  supervisor:delete_child(flu_streams, Name).


lookup_in_config(Path, [{live, Prefix, Options}|Config]) ->
  PrefixLen = size(Prefix),
  case Path of
    <<Prefix:PrefixLen/binary, "/", _Stream/binary>> -> {ok, Path, Options};
    _ -> lookup_in_config(Path, Config)
  end;

lookup_in_config(Path, [{stream, Path, URL, Opts}|_Config]) ->
  {ok, Path, [{url,URL}|Opts]};

lookup_in_config(Path, [_|Config]) ->
  lookup_in_config(Path, Config);

lookup_in_config(_, []) ->
  undefined.


autostart(Name, Options) when is_binary(Name) ->
  StreamSup = {Name, {flu_stream, start_link, [Name, Options]}, temporary, infinity, supervisor, []},
  gen_tracker:find_or_open(flu_streams, StreamSup).




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%
%  Query one stream data
%

media_info(Stream) ->
  touch(Stream),
  case gen_tracker:getattr(flu_streams, Stream, media_info) of
    {ok, MI} -> MI;
    undefined ->
      {ok, Pid} = autostart(Stream),
      gen_server:call(Pid, {get, media_info})
  end.

% HDS
hds_manifest(Stream) ->
  % Called when a user connects to HDS stream
  touch(Stream),
  gen_tracker:getattr(flu_streams, Stream, hds_manifest).

hds_manifest(_Stream, 0) -> undefined;
hds_manifest(Stream, Retries) ->
  case hds_manifest(Stream) of
    undefined -> timer:sleep(100), hds_manifest(Stream, Retries - 1);
    Else -> Else
  end.

hds_manifest(Stream, Retries, Token) ->
  case hds_manifest(Stream, Retries) of
    {ok, Manifest} -> rewrite_manifest(Manifest, Token);
    Else -> Else
  end.

rewrite_manifest(Manifest, Token) when is_binary(Manifest) andalso is_binary(Token) ->
  Manifest1 = binary:replace(Manifest, <<"url=\"bootstrap\"">>, 
    <<"url=\"bootstrap?token=",Token/binary, "\"">>),
  {ok, Manifest1}.

bootstrap(Stream) ->
  touch(Stream),
  gen_tracker:getattr(flu_streams, Stream, bootstrap, 10).

hds_fragment(Stream,Fragment) ->
  touch(Stream),
  case gen_tracker:getattr(flu_streams, Stream, {hds_fragment, 1, Fragment}) of
    {ok, Bin} ->
      gen_tracker:increment(flu_streams, Stream, bytes_out, iolist_size(Bin)),
      {ok, Bin};
    Else ->
      Else
  end.

% HLS
hls_playlist(Stream) ->
  touch(Stream),
  gen_tracker:getattr(flu_streams, Stream, hls_playlist).

hls_playlist(_, 0) -> undefined;
hls_playlist(Stream, Retries) ->
  case hls_playlist(Stream) of
    undefined -> timer:sleep(100), hls_playlist(Stream, Retries - 1);
    Else -> Else
  end.

hls_segment(Root, Stream, Segment) ->
  touch(Stream),
  hls_dvr_packetizer:segment(Root, Stream, Segment).

preview_jpeg(Root, Stream, Segment) ->
  hls_dvr_packetizer:preview_jpeg(Root, Stream, Segment).

hls_key(Stream, Number) ->
  touch(Stream),
  gen_tracker:getattr(flu_streams, Stream, {hls_key, Number}).
  



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%
%  Publish to stream and change options
%





send_frame(Stream, #video_frame{} = Frame) when is_pid(Stream) ->
  
  case erlang:process_info(Stream, message_queue_len) of
    {message_queue_len, MsgCount} when MsgCount > 40 ->
      timer:sleep(500),
      {error, busy};
    undefined ->
      {error, nostream};
    _ ->
      try gen_server:call(Stream, Frame)
      catch
        exit:{timeout, _} ->
          Dict = case process_info(Stream, dictionary) of
            {dictionary, Dict_} -> Dict_;
            undefined -> []
          end,
          Name = proplists:get_value(name, Dict, <<"dead stream">>),
          Status = proplists:get_value(status, Dict),
          lager:error("failed to send frame to ~s (~p) in status ~p, ~p", [Name, Stream, Status, erlang:get_stacktrace()]),
          % [io:format("~10.. s: ~p~n", [K,V]) || {K,V} <- process_info(Stream)]
          {error, timeout}
      end
  end.



subscribe(Stream) when is_binary(Stream) ->
  {ok, {stream, Pid}} = flu_media:find_or_open(Stream),
  subscribe(Pid, []).

subscribe(Stream, Options) when is_binary(Stream) ->
  {ok, Pid} = autostart(Stream, Options),
  subscribe(Pid, Options);

subscribe(Pid, Options) when is_pid(Pid) ->
  erlang:monitor(process, Pid),
  gen_server:call(Pid, {subscribe, self(), Options}).

set_source(Stream, Source) when is_pid(Stream) andalso (is_pid(Source) orelse Source == undefined) ->
  gen_server:call(Stream, {set_source, Source}).

set_last_dts(DTS, Now) ->

  erlang:put(last_dts_at, Now),
  erlang:put(last_dts, DTS),
  FirstDTS = case erlang:get(first_dts) of
    undefined -> put(first_dts, DTS), DTS;
    FDTS -> FDTS
  end,

  Lifetime = DTS - FirstDTS,
  case Lifetime of
    Lifetime1 when Lifetime1 > 15000 ->
      case erlang:get(already_ready) of
        undefined -> 
          put(already_ready, true),
          notify_webhook(get(name), "stream_started");
        _ -> ok
      end;
    _ -> ok
  end, 
  gen_tracker:setattr(flu_streams, get(name), [{last_dts, DTS},{last_dts_at,Now},{lifetime,Lifetime}]).

non_static(Stream) ->
  case find(Stream) of
    {ok, Pid} -> Pid ! non_static;
    _ -> false
  end.

static(Stream) ->
  case find(Stream) of
    {ok, Pid} -> Pid ! static;
    _ -> false
  end.

update_options(Stream, Options) ->
  case find(Stream) of
    {ok, Pid} -> gen_server:call(Pid, {update_options, Options}, 1000);
    _ -> false
  end.

touch(Stream) ->
  gen_tracker:setattr(flu_streams, Stream, [{last_access_at, os:timestamp()}]).


%%%===================================================================
%%% API
%%%===================================================================
start_link(Name,Options) ->
  proc_lib:start_link(?MODULE, init, [[Name,Options]]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name,Options1]) ->
  put(status, booting),
  put(helpers, []),
  process_flag(trap_exit, true),
  Options = lists:umerge(lists:usort(Options1), [{name,Name}]),
  erlang:put(name, Name),
  Source = proplists:get_value(source, Options1),
  if is_pid(Source) -> erlang:monitor(process, Source); true -> ok end,
  CheckTimer = erlang:send_after(3000, self(), check_timeout),
  Now = os:timestamp(),
  ClientCount = flu_session:client_count(Name),
  gen_tracker:setattr(flu_streams, Name, [{last_access_at,Now},{client_count,ClientCount},{bytes_in,0},{bytes_out,0}]),
  Stream1 = #stream{last_dts_at=Now,
    name = Name, options = Options, source = Source,
    check_timer = CheckTimer},
  % timer:send_interval(1000, next_second),
  proc_lib:init_ack({ok, self()}),

  Stream2 = set_options(Stream1),
  
  lager:notice("Start stream \"~s\" with url ~p and options: ~p", [Name, Stream2#stream.url, Options]),

  flu_event:stream_started(Name, [{K,V} || {K,V} <- gen_tracker:info(flu_streams, Name), lists:member(K,white_keys())]),

  {noreply, Stream3} = ?MODULE:handle_info(reconnect_source, Stream2),
  GopFlush = erlang:send_after(4*?SEGMENT_DURATION*1000, self(), gop_flush),
  GopOpen = os:timestamp(),
  gen_server:enter_loop(?MODULE, [], Stream3#stream{gop_flush = GopFlush, gop_open = GopOpen}).


set_options(#stream{options = Options, name = Name, url = URL1, source = Source1} = Stream) ->
  {URL, Source} = case proplists:get_value(url, Options) of
    URL1 -> {URL1, Source1};
    URL2 ->
      (catch erlang:exit(Source1, normal)),
      self() ! reconnect_source,
      {URL2, undefined}
  end,
  Stream1 = set_timeouts(Stream),
  Dump = proplists:get_value(dump, Options),
  Stream2 = configure_packetizers(Stream1),
  put(status, {setattr,url,URL}),
  gen_tracker:setattr(flu_streams, Name, [{url,URL}]),
  Stream2#stream{url = URL, source = Source, dump_frames = Dump}.

set_timeouts(#stream{options = Options} = Stream) ->
  Timeout = proplists:get_value(timeout, Options, ?TIMEOUT),
  SourceTimeout = proplists:get_value(source_timeout, Options, ?SOURCE_TIMEOUT),
  ClientsTimeout = proplists:get_value(clients_timeout, Options, Timeout),
  RetryLimit = proplists:get_value(retry_limit, Options, ?RETRY_LIMIT),
  Static = proplists:get_bool(static, Options),
  Stream#stream{retry_limit = RetryLimit, source_timeout = SourceTimeout, clients_timeout = ClientsTimeout, timeout = Timeout, static = Static}.


init_if_required({Module, ModState} = State, Module, Options) ->
  case erlang:function_exported(Module, update_options, 2) of
    true ->
      {ok, ModState1} = Module:update_options(Options, ModState),
      {Module, ModState1};
    false ->
      State
  end;

init_if_required(_, Module, Options) ->
  case code:is_loaded(Module) of
    false -> code:load_file(Module);
    _ -> ok
  end,
  case erlang:function_exported(Module, init, 1) of
    true ->
      % ?D({init,Module,Options}),
      {ok, State} = Module:init(Options),
      {Module, State};
    false ->
      ?D({cant_init,Module,Options}),
      {blank_packetizer, blank}
  end.

shutdown_packetizer(undefined) ->
  ok;
  
shutdown_packetizer({Module,State}) ->
  Module:terminate(normal, State).
  

configure_packetizers(#stream{hls = HLS1, hds = HDS1, udp = UDP1, options = Options, media_info = MediaInfo} = Stream) ->
  put(status, {configure,hls}),
  HLS = case proplists:get_value(hls, Options) of
    false -> shutdown_packetizer(HLS1), {blank_packetizer, undefined};
    _ -> init_if_required(HLS1, hls_dvr_packetizer, Options)
  end,
  put(status, {configure,hds}),
  HDS = case proplists:get_value(hds, Options) of
    false -> shutdown_packetizer(HDS1), {blank_packetizer, undefined};
    _ -> init_if_required(HDS1, hds_packetizer, Options)
  end,
  % ?D({configuring,Options, proplists:get_value(dvr,Options)}),
  put(status, {configure,udp}),
  UDP = case proplists:get_value(udp, Options) of
    undefined -> shutdown_packetizer(UDP1), {blank_packetizer, undefined};
    Dest when is_list(Dest) orelse is_binary(Dest) -> init_if_required(UDP1, udp_packetizer, Options);
    OtherUDP -> lager:error("Invalid {udp,~p} option, need {udp,\"udp://239.0.0.1:5000\"}", [OtherUDP]), {blank_packetizer, undefined}
  end,
  put(status, {pass,media_info}),
  Stream1 = pass_message(MediaInfo, Stream#stream{hls = HLS, hds = HDS, udp = UDP}),
  Stream2 = configure_push(Stream1),
  Stream2.

configure_push(#stream{push = Push1, options = Options, name = Name} = Stream) ->
  put(status, {configure,push}),
  NewPush = [iolist_to_binary([URL, "/", Name]) || {push,URL} <- Options],
  
  LeavingOld = lists:flatmap(fun(URL) ->
    case lists:member(URL, NewPush) of
      true -> [URL];
      false -> stop_helper(Name, {push, URL}),[]
    end
  end, Push1),

  StartingNew = lists:flatmap(fun(URL) ->
    case lists:member(URL, LeavingOld) of
      true -> [];
      false -> start_helper(Name, {push, URL}, {flu_pusher, start_link, [Name,URL]}), [URL]
    end
  end, NewPush),

  Push2 = StartingNew ++ LeavingOld,
  Stream#stream{push = Push2}.



%% Helpers

handle_call({find_helper, Id}, _From, #stream{name = Name} = Stream) ->
  {reply, find_helper(Name, Id), Stream};

handle_call({delete_child, Id}, _From, #stream{name = Name} = Stream) ->
  {reply, stop_helper(Name, Id), Stream};

handle_call({start_helper, Id, MFA}, _From, #stream{name = Name} = Stream) ->
  {reply, start_helper(Name, Id, MFA), Stream};

handle_call(which_children, _From, #stream{} = Stream) ->
  Children = [{Id, Pid, worker, []} || #helper{id = Id, pid = Pid} <- get(helpers)],
  {reply, Children, Stream};

handle_call({update_options, NewOptions}, _From, #stream{name = Name} = Stream) ->
  NewOptions1 = lists:ukeymerge(1, lists:ukeysort(1, NewOptions), [{name,Name}]),
  % ?D({updating_options,NewOptions1}),
  Stream1 = set_options(Stream#stream{options = NewOptions1}),
  {reply, ok, Stream1};

handle_call(start_monotone, _From, #stream{} = Stream) ->
  {ok, M, Stream1} = start_monotone_if_need(Stream),
  {reply, {ok, M}, Stream1};


handle_call({subscribe, Pid, Options}, _From, #stream{} = Stream) ->
  {ok, Monotone, Stream1} = start_monotone_if_need(Stream),
  put(status, subscribe_pid_to_monotone),
  % TODO: make subscribing to events via ets table
  {Proto, Socket} = case proplists:get_value(proto, Options) of
    undefined -> {raw, undefined};
    Proto_ ->
      case lists:keyfind(socket, 1, Options) of
        false -> {raw, undefined};
        {socket, Socket_} -> {Proto_, Socket_}
      end
  end,

  Reply = flu_monotone:add_client(Monotone, Pid, Proto, Socket),
  {reply, Reply, Stream1};

handle_call({set_source, undefined}, _From, #stream{source_ref = Ref} = Stream) ->
  case Ref of
    undefined -> ok;
    _ -> erlang:demonitor(Ref, [flush])
  end,
  {reply, ok, Stream#stream{source = undefined, source_ref = undefined}};

handle_call({set_source, Source}, _From, #stream{source = OldSource} = Stream) ->
  OldSource == undefined orelse error({reusing_source,Stream#stream.name,OldSource,Source}),
  Ref = erlang:monitor(process, Source),
  {reply, ok, Stream#stream{source = Source, source_ref = Ref}};

handle_call(#media_info{} = MediaInfo, _From, #stream{} = Stream) ->
  {noreply, Stream1} = handle_info(MediaInfo, Stream),
  {reply, ok, Stream1};

handle_call({set, #media_info{} = MediaInfo}, _From, #stream{} = Stream) ->
  {noreply, Stream1} = handle_info(MediaInfo, Stream),
  {reply, ok, Stream1};

handle_call({get, media_info}, _From, #stream{name = Name, media_info = MediaInfo} = Stream) ->
  Now = os:timestamp(),
  put(status, {setattr,last_access_at}),
  gen_tracker:setattr(flu_streams, Name, [{last_access_at, Now}]),
  {reply, MediaInfo, Stream};

handle_call({get, Key}, _From, #stream{name = Name} = Stream) ->
  Reply = case erlang:get(Key) of
    undefined -> undefined;
    Else -> {ok, Else}
  end,
  touch(Name),
  {reply, Reply, Stream};

handle_call(#video_frame{} = Frame, _From, #stream{name = Name} = Stream) ->
  put(status, handle_input_frame),
  gen_tracker:increment(flu_streams, Name, bytes_in, erlang:external_size(Frame)),
  {noreply, Stream1} = handle_input_frame(Frame, Stream),
  {reply, ok, Stream1};

handle_call(_Call,_From,State) ->
  {stop,{unknown_call, _Call},State}.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end

%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(non_static, #stream{} = Stream) ->
  {noreply, Stream#stream{static = false}};

handle_info(static, #stream{} = Stream) ->
  {noreply, Stream#stream{static = true}};

handle_info(reconnect_source, #stream{url = undefined} = Stream) ->
  {noreply, Stream};

handle_info(reconnect_source, #stream{source = Source} = Stream) when is_pid(Source) ->
  {noreply, Stream};

handle_info(reconnect_source, #stream{retry_count = Count, name = Name, retry_limit = Limit, static = false} = Stream) when Count*1 >= Limit*1 ->
  lager:info("Stream ~s exits due to retry limit ~B", [Name, Count]),
  {stop, normal, Stream};


handle_info({'$set_opened_at', OpenedAt}, #stream{} = Stream) ->
  {noreply, Stream#stream{gop_open = OpenedAt}};

handle_info(reconnect_source, #stream{source = undefined, name = Name, url = URL1, retry_count = Count, options = Options} = Stream) ->
  {Proto, URL} = detect_proto(URL1),
  LogError = will_log_error(Count),
  put(status, {reconnect,URL}),
  Result = case Proto of
    tshttp -> flu_mpegts:read(Name, URL, [{name,Name}]);
    udp -> flu_mpegts:read(Name, URL, [{name,Name}]);
    udp2 -> flu_mpegts:read(Name, URL, [{name,Name}]);
    rtsp -> flu_rtsp:read2(Name, URL, [{log_error,LogError}|Options]);
    rtsp2 -> flu_rtsp:read2(Name, URL, [{log_error,LogError}|Options]);
    rtsp1 -> flu_rtsp:read(Name, URL, Options);
    hls -> hls:read(Name, URL, [{log_error,LogError}|Options]);
    file -> file_source:read(URL, Options);
    rtmp -> flu_rtmp:play_url(Name, URL, Options);
    playlist -> playlist:read(Name, URL, Options);
    mixer -> flu_mixer:read(Name, URL, Options);
    timeshift -> timeshift:read(Name, URL, [{log_error,LogError}|Options]);
    passive -> {ok, undefined}
  end,
  case Result of
    {ok, Source} -> 
      Ref = erlang:monitor(process, Source),
      {noreply, Stream#stream{source = Source, source_ref = Ref}};
    {ok, Source, MediaInfo} -> 
      Ref = erlang:monitor(process, Source),
      {noreply, Stream1} = handle_info(MediaInfo, Stream#stream{media_info = undefined, source = Source, source_ref = Ref}),
      Configs = video_frame:config_frames(MediaInfo),
      Stream2 = lists:foldl(fun(C, Stream_) ->
        {_,Stream1_} = flu_stream_frame:save_config(C, Stream_),
        Stream1_
      end, Stream1, Configs),
      {noreply, Stream2};
    {error, Error} ->
      if LogError -> lager:error("Stream \"~s\" can't open source \"~s\" (~p). Retries: ~B/~B", [Name, URL, Error, Count, Stream#stream.retry_limit]);
      true -> ok end,
      Delay = ((Count rem 30) + 1)*1000,
      erlang:send_after(Delay, self(), reconnect_source),
      gen_tracker:setattr(flu_streams, Name, [{retry_count,Count+1}]),
      {noreply, Stream#stream{retry_count = Count+1}}
  end;

handle_info(#media_info{} = MediaInfo, #stream{name = Name, monotone = Monotone} = Stream) ->
  gen_tracker:setattr(flu_streams, Name, [{media_info, MediaInfo}]),
  Stream1 = pass_message(MediaInfo, Stream#stream{media_info = MediaInfo}),
  flu_monotone:send_media_info(Monotone, MediaInfo),
  {noreply, Stream1};

handle_info({'EXIT', Pid, _Reason}, #stream{name = Name} = Stream) ->
  case lists:keytake(Pid, #helper.pid, get(helpers)) of
    {value, #helper{id = Id, mfa = MFA}, Helpers1} ->
      put(helpers, Helpers1),
      start_helper(Name, Id, MFA);
    false ->
      ok
  end,
  {noreply, Stream};

handle_info({'DOWN', _, process, Monotone, _Reason}, #stream{monotone = Monotone, url = URL} = Stream) ->
  lager:error("Mototone crashed for stream \"~s\" with reason: ~p", [URL, _Reason]),
  {noreply, Stream#stream{monotone = undefined}};

handle_info({'DOWN', _, process, Source, _Reason}, 
  #stream{source = Source, retry_count = Count, name = Name, url = URL, retry_limit = Limit} = Stream) ->
  Delay = ((Count rem 30) + 1)*1000,
  erlang:send_after(Delay, self(), reconnect_source),
  LogError = will_log_error(Count),
  if LogError -> lager:error("stream \"~s\" lost source \"~s\". Retry count ~p/~p", [Name, URL, Count, Limit]);
  true -> ok end,
  gen_tracker:setattr(flu_streams, Name, [{retry_count,Count+1}]),
  {noreply, Stream#stream{source = undefined, ts_delta = undefined, retry_count = Count + 1}};

handle_info(check_timeout, #stream{name = Name, static = Static, check_timer = OldCheckTimer,
  source_timeout = SourceTimeout, url = URL, source = Source, last_dts_at = LastDtsAt, retry_count = Count,
  clients_timeout = ClientsTimeout, monotone = Monotone} = Stream) ->
  
  erlang:cancel_timer(OldCheckTimer),
  Now = os:timestamp(),
  SourceDelta = timer:now_diff(Now, LastDtsAt) div 1000,
  {ok, LastTouchedAt} = gen_tracker:getattr(flu_streams, Name, last_access_at),
  ClientsDelta = timer:now_diff(Now, LastTouchedAt) div 1000,

  UsingSourceTimeout = if is_number(SourceTimeout) -> lists:max([Count,1])*SourceTimeout;
    true -> SourceTimeout end,

  % ?D({{source_delta,SourceDelta},{clients_delta,ClientsDelta}}),
  CheckTimer = erlang:send_after(3000, self(), check_timeout),


  put(status, monotone_clients_count),
  ClientsCount = flu_monotone:clients_count(Monotone),

  if 
  is_number(ClientsTimeout) andalso not Static andalso ClientsDelta >= ClientsTimeout andalso ClientsCount == 0 ->
    lager:error("Stop stream \"~s\" (url \"~s\"): no clients during timeout: ~p/~p", [Name, URL, ClientsDelta,ClientsTimeout]),
    {stop, normal, Stream};
  is_number(SourceTimeout) andalso SourceDelta >= UsingSourceTimeout andalso is_pid(Source) ->
    erlang:exit(Source, shutdown),
    case will_log_error(Count) of true ->
    lager:error("stream \"~s\" is killing source \"~s\" because of timeout ~B > ~B", [Name, URL, SourceDelta, Count*SourceTimeout]);
    false -> ok end,
    erlang:exit(Source, kill),
    {noreply, Stream#stream{check_timer = CheckTimer}};
  is_number(SourceTimeout) andalso SourceDelta >= SourceTimeout andalso not Static ->
    lager:error("Stop non-static stream \"~s\" (url ~p): no source during ~p/~p", [Name, URL, SourceDelta,SourceTimeout]),
    {stop, normal, Stream};
  SourceTimeout == false andalso URL == undefined andalso Source == undefined andalso not Static ->
    ?D({no_url,no_source, Name, stopping}),
    {stop, normal, Stream};  
  true ->  
    {noreply, Stream#stream{check_timer = CheckTimer}}
  end;

handle_info(reload_playlist, #stream{source = Source} = Stream) ->
  Source ! reload_playlist,
  {noreply, Stream};

handle_info({'DOWN', _, _, _, _} = Message, #stream{} = Stream) ->
  {noreply, pass_message(Message, Stream)};

handle_info(#video_frame{} = Frame, #stream{name = Name} = Stream) ->
  gen_tracker:increment(flu_streams, Name, bytes_in, erlang:external_size(Frame)),
  {noreply, Stream1} = handle_input_frame(Frame, Stream),
  {noreply, Stream1};

handle_info(#gop{mpegts = Mpegts, frames = undefined} = Gop, #stream{} = Stream) when Mpegts =/= undefined ->
  {ok, Frames} = mpegts_decoder:decode_file(Mpegts),
  Gop1 = case Frames of
    [] -> Gop#gop{frames = Frames};
    [#video_frame{dts = DTS}|_] -> Gop#gop{frames = Frames, dts = DTS}
  end,
  handle_info(Gop1, Stream);

handle_info(#gop{frames = [_|_] = Frames} = Gop, #stream{media_info = undefined} = Stream) ->
  #media_info{} = MediaInfo = video_frame:define_media_info(undefined, Frames),
  {noreply, Stream1} = handle_info(MediaInfo, Stream),
  handle_info(Gop, Stream1);

handle_info(#gop{frames = [Frame|_]} = Gop, #stream{name = Name} = Stream) ->
  {_,Stream1} = flu_stream_frame:save_last_dts(Frame, Stream),
  set_last_dts(Stream1#stream.last_dts, Stream1#stream.last_dts_at),
  gen_tracker:increment(flu_streams, Name, bytes_in, erlang:external_size(Gop)),
  Stream2 = pass_message(Gop, Stream1),
  {noreply, Stream2};

% handle_info(next_second, #stream{last_dts = DTS, ts_delta = Delta} = Stream) when DTS =/= undefined andalso Delta =/= undefined ->
%   {_, _, Microsecond} = Now = erlang:now(),
%   {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_local_time(Now),
%   Millisecond = Microsecond div 1000,
%   SD = io_lib:format("~2.. B-~2.. B-~4.. B", [Day, Month, Year]),
%   ST = io_lib:format("~2.. B:~2.. B:~2.. B:~3.. B", [Hour, Minute, Second, Millisecond]),
%   Metadata = #video_frame{dts = DTS - Delta, pts = DTS - Delta, content = metadata, body = [
%     <<"onFI">>, [{sd, iolist_to_binary(SD)}, {st, iolist_to_binary(ST)}]
%   ]},
%   handle_info(Metadata, Stream);

handle_info(Message, #stream{} = Stream) ->
  Stream1 = pass_message(Message, Stream),
  {noreply, Stream1}.











handle_input_frame(#video_frame{} = Frame, #stream{retry_count = Count, name = Name} = Stream) when Count > 0 ->
  gen_tracker:setattr(flu_streams, Name, [{retry_count,0}]),
  handle_input_frame(Frame, Stream#stream{retry_count = 0});
  
handle_input_frame(#video_frame{} = Frame, #stream{name = Name, dump_frames = Dump} = Stream) ->
  case Dump of
    true -> ?D({frame, Name, Frame#video_frame.codec, Frame#video_frame.flavor, Frame#video_frame.track_id, round(Frame#video_frame.dts), round(Frame#video_frame.pts)});
    _ -> ok
  end,
  {reply, Frame1, Stream2} = flu_stream_frame:handle_frame(Frame, Stream),
  put(status, {pass,message}),
  Stream3 = pass_message(Frame1, Stream2),
  
  set_last_dts(Stream3#stream.last_dts, Stream3#stream.last_dts_at),
  Stream4 = feed_gop(Frame1, Stream3),
  {noreply, Stream4}.


% TODO: move flu_monotone:send_frame here and mark this frame as a gop-starter
feed_gop(#video_frame{flavor = keyframe, dts = DTS} = F, #stream{gop_flush = OldGopFlush, gop = RGop, monotone = M,
  gop_open = GopOpen, gop_start_dts = StartDTS} = Stream) 
  when length(RGop) > 0 andalso DTS - StartDTS >= ?SEGMENT_DURATION*1000 ->
  catch erlang:cancel_timer(OldGopFlush),
  Stream1 = case lists:reverse(RGop) of
    [] -> Stream;
    [#video_frame{dts = StartDTS}|_] = Gop -> pass_message(#gop{opened_at = GopOpen, frames = Gop, duration = DTS - StartDTS}, Stream)
  end,
  flu_monotone:send_frame(M, F#video_frame{next_id = gop}),
  GopFlush = erlang:send_after(4*?SEGMENT_DURATION*1000, self(), gop_flush),
  Stream1#stream{gop_flush = GopFlush, gop_open = os:timestamp(), gop_start_dts = DTS, gop = [F]};

feed_gop(#video_frame{dts = DTS} = F, #stream{gop = [], monotone = M} = Stream) ->
  flu_monotone:send_frame(M, F#video_frame{next_id = undefined}),
  Stream#stream{gop = [F], gop_open = os:timestamp(), gop_start_dts = DTS};

feed_gop(#video_frame{} = F, #stream{gop = Gop, monotone = M} = Stream) ->
  flu_monotone:send_frame(M, F#video_frame{next_id = undefined}),
  Stream#stream{gop = [F|Gop]}.







start_monotone_if_need(#stream{name = Name, last_dts = DTS, monotone = undefined, media_info = MediaInfo, options = Options} = Stream) ->
  put(status, start_monotone),
  case find_helper(Name, monotone) of
    {ok, M} ->
      {ok, M, Stream#stream{monotone = M}};
    undefined ->
      {ok, M} = start_helper(Name, monotone, {flu_monotone, start_link, [Name,Options]}),
      flu_monotone:send_media_info(M, MediaInfo),
      flu_monotone:set_current_dts(M, DTS),
      {ok, M, Stream#stream{monotone = M}}
  end;

start_monotone_if_need(#stream{monotone = M1} = Stream) ->
  {ok, M1, Stream}.



will_log_error(Count) ->
  Count =< 10 orelse 
  (Count < 500 andalso Count div 10 == 0) orelse
  Count rem 100 == 0.


pass_message(Message, Stream) ->
  try pass_message0(Message, Stream)
  catch
    Class:Error ->
      lager:error("Failed to pass message ~p: ~p:~p~n~p", [Message, Class, Error, erlang:get_stacktrace()]),
      erlang:raise(Class, Error, erlang:get_stacktrace())
  end.

pass_message0(Message, #stream{hls = {HLSMod, HLS}, hds = {HDSMod, HDS}, udp = {UDPMod, UDP}} = Stream) ->
  put(status, {pass,message,hls}),
  {noreply, HLS1} = HLSMod:handle_info(Message, HLS),
  put(status, {pass,message,hds}),
  {noreply, HDS1} = HDSMod:handle_info(Message, HDS),
  put(status, {pass,message,udp}),
  {noreply, UDP1} = UDPMod:handle_info(Message, UDP),
  Stream#stream{hls = {HLSMod, HLS1}, hds = {HDSMod, HDS1}, udp = {UDPMod, UDP1}}.

detect_proto(<<"file://", Path/binary>>) ->
  {file, Path};

detect_proto(URL) ->
  {Proto, _Auth, _Host, _Port, _Path, _} = http_uri2:parse(URL),
  {Proto, URL}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #stream{name = Name}) ->
  [stop_helper(Name,Id) || #helper{id = Id} <- get(helpers)],
  ok.


% TODO send stream.stopped event
after_terminate(Name, Attrs) ->
  Keys = [hls,hds,rtmp,bytes_in,bytes_out,client_count,last_dts,url,lifetime],
  Stats = [{K,V} || {K,V} <- Attrs, lists:member(K,Keys)],
  notify_webhook(Name, "stream_stopped"),
  flu_event:stream_stopped(Name, Stats),
  ok.


notify_webhook(Name, Event) ->
  lager:error("Notify webhook ~p ~p", [Name, Event]),
  {match,[Prefix, Stream]} = re:run(Name,"(.*)/(.*)",[{capture,all_but_first,binary}]),
  Env = flu_config:get_config(),
  Options = case [Entry || {live,Pref,_Options} = Entry <- Env, Pref == Prefix] of
  [{live, Prefix, Opts}] -> Opts;
  [] ->
    lager:error("Hook from invalid RTMP app ~s ~s", [Prefix, Stream]),
    ok
  end,
  
  case proplists:get_value(webhook, Options) of
    ApiEndpoint when ApiEndpoint =/= undefined ->
      EndPoint = binary_to_list(iolist_to_binary([ApiEndpoint, "/", Stream, "?event=", Event])),
      case lhttpc:request(EndPoint, "GET", [], 30000) of
        {ok,{{Code,_},_Headers,_Body}} when Code == 200 orelse Code == 302 ->
          ok;
        {ok,{{500,_},_Headers,_Body}} ->
          lager:error("500 error on api: ~p", [_Body]);
        {error, _} ->
          lager:error("Unabled to connect to api.", [])
      end
  end,
  ok.
  

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
