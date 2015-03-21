%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2012 Max Lapshin
%%% @doc        rtmp
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
-module(flu_rtmp).
-author('Max Lapshin <max@maxidoors.ru>').
-include_lib("rtmp/include/rtmp.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("log.hrl").

-export([create_client/1]).
-export([init/1, handle_control/2, handle_rtmp_call/2, handle_info/2]).
-export([no_function/2, publish/2, play/2, seek/2, flu_stats/2]).

-export([play_url/3]).
-export([lookup_config/3]).


-export([clients/0]).

clients() ->
  case erlang:whereis(rtmp_session_sup) of
    undefined ->
      [];
    _ ->
      clients0()
  end.

clients0() ->
  Now = flu:now_ms(),
  Pids = [Pid || {_, Pid, _, _} <- supervisor:which_children(rtmp_session_sup)],
  Clients = [begin
    {dictionary, Info} = process_info(Pid, dictionary),
    Ip = case proplists:get_value(remote_ip, Info) of
      undefined -> [];
      Ip_ -> [{ip,Ip_}]
    end,
    case proplists:get_value(rtmp_play, Info) of
      undefined ->
        undefined;
      {_Type, Name, StartAt} ->
        Ip ++ [{type,<<"rtmp">>},{pid,Pid},{name,Name},{start_at, StartAt}, {duration, Now - StartAt}]
    end
  end || Pid <- Pids],
  [Client || Client <- Clients, Client =/= undefined].

play_url(Name, URL, Options) ->
  RTMPOptions = proplists:get_value(rtmp_play, Options, []),
  {ok, Proxy} = flu_stream:start_helper(Name, publish_proxy, {flu_publish_proxy, start_link, [URL, self(), RTMPOptions]}),
  {ok, Proxy}.
  

create_client(RTMP) ->
  {ok, Pid} = supervisor:start_child(rtmp_session_sup, [?MODULE]),
  rtmp_session:set_socket(Pid, RTMP),
  {ok, Pid}.
  
init(Session) ->
  put(sent_bytes, 0),
  {ok, Session}.

handle_control({stream_died, _}, Session) ->
  self() ! exit,
  {ok, Session};

handle_control(_Control, Session) ->
  {ok, Session}.

flush_burst_timer(Session) ->
  receive
    {read_burst, _, _, _} -> flush_burst_timer(Session)
  after
    0 ->
      case rtmp_session:get(Session, burst_timer) of
        undefined -> ok;
        Timer -> erlang:cancel_timer(Timer)
      end
  end.

handle_info({read_burst, StreamId, Fragment, BurstCount}, Session) ->
  flush_burst_timer(Session),
  Stream = rtmp_session:get_stream(StreamId, Session),
  Media = rtmp_stream:get(Stream, pid),
  case flu_file:read_gop(Media, Fragment) of
    {ok, Gop} ->
      {noreply, Session1} = rtmp_session:handle_info({ems_stream, StreamId, burst_start}, Session),

      Bin = [begin
        FlvFrameGen = flv:rtmp_tag_generator(Frame),
        FlvFrameGen(0, StreamId)
      end || Frame <- Gop],
      Duration = (lists:last(Gop))#video_frame.dts - (hd(Gop))#video_frame.dts,

      RTMP = rtmp_session:get(Session, socket),
      {rtmp, Socket} = try rtmp_socket:get_socket(RTMP)
      catch
        exit:{_, _} -> throw({stop, normal, Session})
      end,

      case gen_tcp:send(Socket, Bin) of
        ok -> ok;
        {error, _} -> throw({stop, normal, Session})
      end,
      Size = iolist_size(Bin),
      put(sent_bytes, get(sent_bytes) + Size),
      SessionId = rtmp_session:get(Session, session_id),
      flu_session:add_bytes(SessionId, Size),

      {noreply, Session2} = rtmp_session:handle_info({ems_stream, StreamId, burst_stop}, Session1),
      Sleep = if BurstCount > 0 -> 0;
        true -> round(Duration)
      end,
      BurstTimer = erlang:send_after(Sleep, self(), {read_burst, StreamId, Fragment+1, BurstCount - 1}),
      Session3 = rtmp_session:set(Session2, burst_timer, BurstTimer),
      {noreply, Session3};
    {error, no_segment} ->
      rtmp_session:handle_info({ems_stream, StreamId, play_complete, 0}, Session)
  end;

handle_info({recording, StreamId, #video_frame{} = Frame}, Session) ->
  self() ! Frame#video_frame{stream_id = StreamId},
  StartAt = rtmp_session:get(Session, start_at),
  F = rtmp_session:get(Session, f),
  case flv:read(F) of
    eof ->
      self() ! {ems_stream, StreamId, play_complete, 0};
    #video_frame{dts = DTS} = Frame1 ->
      Delay = lists:max([round(DTS) - timer:now_diff(os:timestamp(), StartAt) div 1000, 0]),
      erlang:send_after(Delay, self(), {recording, StreamId, Frame1}),
      {noreply, Session}
  end;



handle_info({'DOWN', _, _, _, _}, State) ->
  {stop, normal, State};

handle_info(#media_info{}, State) ->
  {noreply, State};

handle_info(stop, State) ->
  {stop, normal, State};

handle_info(flush_bytes, State) ->
  Bytes1 = get(bytes),
  Socket = rtmp_session:get(State, tcp_socket),
  SessionId = rtmp_session:get(State, session_id),
  {ok, [{send_oct,Bytes2}]} = inet:getstat(Socket, [send_oct]),
  flu_session:add_bytes(SessionId, Bytes2 - Bytes1),
  erlang:send_after(1000, self(), flush_bytes),
  {noreply, State};


handle_info(refresh_auth, State) ->
  case get(auth_info) of
    undefined ->
      {noreply, State};
    {URL, Identity, AuthOptions} ->
      case flu_session:verify(URL, Identity, AuthOptions) of
        {ok, _} ->
          {noreply, State};
        {error, Code, Message} ->
          App = rtmp_session:get_field(State, app),
          {_Type,StreamName1,StartAt} = get(rtmp_play),
          Token = proplists:get_value(token,Identity),
          Delay = (flu:now_ms() - StartAt) div 1000,
          lager:info("refreshing auth denied play(~s/~s) with token(~s) started ~B seconds ago: ~p:~p", 
            [App, StreamName1, Token, Delay, Code, Message]),
          {stop, normal, State}
      end
  end;

handle_info(_Info, State) ->
  ?D({_Info}),
  {noreply, State}.
  


handle_rtmp_call(Session, AMF) ->
  ChainList = proplists:get_value(rtmp_handlers, flu_config:get_config(), [?MODULE]),
  case (catch call_mfa(ChainList, Session, AMF)) of
    reject ->
      rtmp_session:reject_connection(Session);
    Reply -> 
      Reply
  end.

mod_name(Mod) when is_tuple(Mod) -> element(1, Mod);
mod_name(Mod) -> Mod.

call_mfa([], Session, AMF) ->
  {unhandled, Session, AMF};

call_mfa([Module|Modules], Session, #rtmp_funcall{command = Command} = AMF) ->
  case code:is_loaded(mod_name(Module)) of
    false -> 
      case code:load_file(mod_name(Module)) of
        {module, _ModName} -> ok;
        _ -> erlang:error({cant_load_file, Module})
      end;
    _ -> ok
  end,
  % ?D({"Checking", Module, Command, ems:respond_to(Module, Command, 2)}),
  case erlang:function_exported(Module, Command, 2) of
    true ->
      case Module:Command(Session, AMF) of
        unhandled -> call_mfa(Modules, Session, AMF);
        {unhandled, NewState, NewAMF} -> call_mfa(Modules, NewState, NewAMF);
        Reply -> Reply
      end;
    false ->
      call_mfa(Modules, Session, AMF)
  end.

normalize_path(<<"mp4:", Path/binary>>) -> Path;
normalize_path(<<"flv:", Path/binary>>) -> Path;
normalize_path(<<"f4v:", Path/binary>>) -> Path;
normalize_path(Path) -> Path.

clear_path(<<"/", Path/binary>>) -> Path;
clear_path(Path) -> Path.


seek(Session, #rtmp_funcall{args = [null,DTS], stream_id = StreamId} = _AMF) ->
  RTMP = rtmp_session:get(Session, socket),
  Stream = rtmp_session:get_stream(StreamId, Session),
  Name = rtmp_stream:get(Stream, name),
  Keyframes = flu_file:keyframes(Name),
  SkipGops = length(lists:takewhile(fun({TS,_}) -> TS < DTS end, Keyframes)),

  flush_burst_timer(Session),
  % ?debugFmt("seek to ~p frament",[SkipGops]),
  self() ! {read_burst, StreamId, SkipGops, 3},
  % ?debugFmt("seek(~p) ~s", [round(DTS), Name]),

  % rtmp_lib:reply(RTMP, AMF),

  rtmp_lib:seek_notify(RTMP, StreamId, DTS),
  Session.


flu_stats(Session, #rtmp_funcall{} = AMF) ->
  rtmp_session:reply(Session, AMF#rtmp_funcall{args = [null, true]}),
  Session.


play(Session, #rtmp_funcall{} = AMF) ->
  try play0(Session, AMF) of
    Session1 -> Session1
  catch
    throw:{fail, Args} ->
      RTMP = rtmp_session:get(Session, socket),
      rtmp_lib:fail(RTMP, AMF#rtmp_funcall{args = [null|Args]}),
      self() ! stop,
      Session
  end.

to_b(undefined) -> undefined;
to_b(List) when is_list(List) -> list_to_binary(List);
to_b(Bin) when is_binary(Bin) -> Bin.


fmt(Fmt, Args) -> iolist_to_binary(io_lib:format(Fmt, Args)).

play0(Session, #rtmp_funcall{args = [null, Path1 | _]} = AMF) ->
  Path2 = normalize_path(Path1),
  Path = clear_path(Path2),
  {StreamName0, QsVals} = http_uri2:parse_path_query(Path),
  App = rtmp_session:get_field(Session, app),


  {StreamName, Type, Args, Options} = case lookup_config(flu_config:get_config(), App, iolist_to_binary(StreamName0)) of
    {error, _} ->
      throw({fail, [404, fmt("failed to find in config ~s/~s", [App, StreamName0])]});
    {ok, Spec} -> Spec
  end,

  lager:info("RTMP play ~s ~s", [Type, StreamName]),

  Session1 = case proplists:get_value(sessions, Options, true) of
    false -> Session;
    URL ->
      Token = iolist_to_binary(proplists:get_value("token", QsVals, uuid:gen())),
      Ip = to_b(rtmp_session:get(Session, addr)),
      is_binary(Ip) orelse error({bad_ip, Ip, Session}),
      Identity = [{name,StreamName},{ip, Ip},{token,Token}],
      Referer = rtmp_session:get_field(Session, pageUrl),
      AuthOptions = [{pid,self()},{referer,Referer},{type,<<"rtmp">>}|Options],
      case flu_session:verify(URL, Identity, AuthOptions) of
        {ok, SessionId} ->
          put(auth_info,{URL,Identity,AuthOptions}),
          rtmp_session:set(Session, session_id, SessionId);
        {error, Code, Message} ->
          lager:info("auth denied play(~s/~s) with token(~s): ~p:~p", [App, StreamName, Token, Code, Message]),
          throw({fail, [403, Code, to_b(Message), App, StreamName, <<"auth_denied">>]})
      end
  end,

  put(remote_ip, rtmp_session:get(Session, addr)),
  put(rtmp_play, {Type, StreamName, flu:now_ms()}),

  case find_or_open_media(Type, StreamName, Args, Options) of
    {ok, Media} when Type == file ->
      play_file(Session1, AMF, StreamName, Media);
    {ok, F} when Type == recording ->
      play_recording(Session1, AMF, StreamName, F);
    {ok, Media} ->
      play_stream(Session1, AMF, StreamName, Media);
    undefined ->
      lager:info("no such file or stream ~s//~s", [App, StreamName]),
      throw({fail, [404, fmt("no such file or stream ~s//~s", [App, StreamName])]});
    {error, _Error} ->
      lager:error("failed to play rtmp ~s//~s: ~p", [App, StreamName, _Error]),
      throw({fail, [500, fmt("failed to play rtmp ~s//~s: ~p", [App, StreamName, _Error])]})
  end.

lookup_config([{file,App,Root,Options}|_], App, Path) ->
  {ok, {iolist_to_binary([App, "/", Path]), file, iolist_to_binary([Root, "/", Path]), Options}};

lookup_config([{live,App,Options}|_], App, Path) ->
  StreamName = iolist_to_binary([App, "/", Path]),
  RecordedPath = case proplists:get_value(path,Options) of
    undefined -> undefined;
    FlvPath -> iolist_to_binary([FlvPath, "/", Path, ".flv"])
  end,
  IsRecording = case flu_stream:find(StreamName) of
    undefined when RecordedPath =/= undefined ->
      case file:read_file_info(RecordedPath) of
        {error, _} -> false;
        {ok, _} -> true
      end;
    _ -> false
  end,
  lager:info("~s is_record:~p ~s", [StreamName, IsRecording, RecordedPath]),
  case IsRecording of
    true -> {ok, {RecordedPath, recording, RecordedPath, Options}};
    false -> {ok, {StreamName, live, StreamName, Options}}
  end;

lookup_config([{stream,Path,URL,Options}|_], _App, Path) ->
  {ok, {Path, stream, URL, Options}};

lookup_config([_|Config], App, Path) ->
  lookup_config(Config, App, Path);

lookup_config([], _, _) ->
  {error, not_found}.


find_or_open_media(file, Name, Path, _Options) ->
  flu_file:autostart(Path, Name);

find_or_open_media(stream, Path, URL, Options) ->
  flu_stream:autostart(Path, [{url,URL}|Options]);

find_or_open_media(recording, Path, _, _Options) ->
  flv:open(Path);

find_or_open_media(live, Path, _, _Options) ->
  % flu_stream:autostart(Path, Options).
  flu_stream:find(Path).

  
play_recording(Session, #rtmp_funcall{stream_id = StreamId}, StreamName, F) ->
  case flv:read(F) of
    eof ->
      throw({fail, [404, fmt("empty recording ~s", [StreamName])]});
    #video_frame{} = Frame ->
      self() ! {recording, StreamId, Frame}
  end,

  RTMP = rtmp_session:get(Session, socket),
  rtmp_lib:play_start(RTMP, StreamId, 0, file),
  Session1 = rtmp_session:set(Session, f, F),
  StartAt = os:timestamp(),
  Session2 = rtmp_session:set(Session1, start_at, StartAt),
  Session2.


play_file(Session, #rtmp_funcall{stream_id = StreamId} = _AMF, StreamName, Media) ->
  erlang:monitor(process, Media),
  case flu_file:media_info(Media) of
    #media_info{} = MediaInfo ->
      Configs = video_frame:config_frames(MediaInfo) ++ [video_frame:meta_frame(MediaInfo)],

      Session1 = rtmp_session:set_stream(rtmp_stream:construct([{pid, Media}, {stream_id, StreamId}, {base_dts,0}, {name, StreamName}, {started, true}]), Session),
      RTMP = rtmp_session:get(Session1, socket),
      rtmp_lib:play_start(RTMP, StreamId, 0, file),
      
      SessionId = rtmp_session:get(Session, session_id),
      rtmp_socket:send(RTMP, #rtmp_message{type = metadata, channel_id = rtmp_lib:channel_id(metadata, StreamId), stream_id = StreamId,
        body = [<<"|SessionId">>, SessionId], timestamp = 0, ts_type = delta}),

      Session2 = lists:foldl(fun(F, Sess) ->
        rtmp_session:send_frame(F#video_frame{stream_id = StreamId}, Sess)
      end, Session1, Configs),
      
      self() ! {read_burst, round(StreamId), 1, 3},
      
      Session2;
    {return, _Code, Msg} ->
      lager:error("failed to play file: ~s", [Msg]),
      throw(reject)
  end.


play_stream(Session, #rtmp_funcall{stream_id = StreamId} = _AMF, StreamName, _StreamName) ->
  {ok, Media} = flu_stream:find(StreamName),
  erlang:monitor(process, Media),
  Session1 = case StreamId of
    1 ->
      RTMP = rtmp_session:get(Session, socket),
      Socket = rtmp_session:get(Session, tcp_socket),
      #media_info{streams = Streams} = media_info(StreamName),
      rtmp_lib:play_start(RTMP, StreamId, 0, live),

      SessionId = rtmp_session:get(Session, session_id),
      rtmp_socket:send(RTMP, #rtmp_message{type = metadata, channel_id = rtmp_lib:channel_id(metadata, StreamId), stream_id = StreamId,
        body = [<<"|SessionId">>, SessionId], timestamp = 0, ts_type = delta}),

      case lists:keyfind(audio, #stream_info.content, Streams) of
        false -> ok;
        _ -> rtmp_socket:notify_audio(RTMP, StreamId, 0)
      end,
      case lists:keyfind(video, #stream_info.content, Streams) of
        false -> ok;
        _ -> rtmp_socket:notify_video(RTMP, StreamId, 0)
      end,
      flu_stream:subscribe(Media, [{proto,rtmp},{socket,Socket}]),
      {ok, [{send_oct,Bytes}]} = inet:getstat(Socket, [send_oct]),
      put(bytes,Bytes),
      erlang:send_after(1000, self(), flush_bytes),
      rtmp_session:set_stream(rtmp_stream:construct([{pid, Media}, {stream_id, StreamId}, {name, StreamName}, 
        {started, true}, {options, [{media_type,stream}]}]), Session);
    _ ->
      flu_stream:subscribe(Media, []),
      rtmp_session:set_stream(rtmp_stream:construct([{pid, Media}, {stream_id, StreamId}, {name, StreamName}, 
        {started, false}, {options, [{media_type,stream}]}]), Session)
  end,
  Session1.


media_info(StreamName) ->
  media_info(StreamName, 50).



media_info(StreamName, 0) ->
  throw({fail,[404, StreamName]});

media_info(StreamName, Count) ->
  case flu_stream:media_info(StreamName) of
    undefined -> timer:sleep(100), media_info(StreamName, Count - 1);
    MI -> MI
  end.



publish(Session, #rtmp_funcall{stream_id = StreamId, args = [null, false|_]} = _AMF) ->
  Stream = rtmp_session:get_stream(StreamId, Session),
  Pid = rtmp_stream:get(Stream, pid),
  erlang:exit(Pid),
  rtmp_session:set_stream(rtmp_stream:set(Stream, pid, undefined), Session);

publish(Session, AMF) ->
  try publish0(Session, AMF)
  catch
    throw:{fail, Args} ->
      RTMP = rtmp_session:get(Session, socket),
      rtmp_lib:fail(RTMP, AMF#rtmp_funcall{args = [null|Args]}),
      throw(shutdown)
  end.


publish0(Session, #rtmp_funcall{stream_id = StreamId, args = [null, Name |PublishArgs]} = _AMF) ->
  Prefix = rtmp_session:get_field(Session, app),
  Env = flu_config:get_config(),

  Options = case [Entry || {live,Pref,_Options} = Entry <- Env, Pref == Prefix] of
    [{live, Prefix, Opts}] -> Opts;
    [] ->
      lager:error("Tried to publish to invalid RTMP app ~s from addr ~p", [Prefix, rtmp_session:get(Session, addr)]),
      throw({fail, [403, <<Prefix/binary, "/", Name/binary>>, <<"no_application">>]})
  end,

  {match,[StreamName1]} = re:run(Name,"([^?]+)\\?*",[{capture,all_but_first,binary}]),
  StreamName = <<Prefix/binary, "/", StreamName1/binary>>,
  Env = flu_config:get_config(),

  {RawName, Args} = http_uri2:parse_path_query(Name),
  


  case proplists:get_value(steamkey_api, Options) of
    ApiEndpoint when ApiEndpoint =/= undefined ->
      EndPoint = binary_to_list(iolist_to_binary([ApiEndpoint, "/", Name])),
      case lhttpc:request(EndPoint, "GET", [], 30000) of
        {ok,{{Code,_},_Headers,_Body}} when Code == 200 orelse Code == 302 ->
          ok;
        {ok,{{403,_},_Headers,_Body}} ->
          lager:error("Publish denied, api returned: ~p", [_Body]),
          throw({fail, [403, StreamName, <<"bad_key">>]});
        {ok,{{500,_},_Headers,_Body}} ->
          lager:error("500 error on api: ~p", [_Body]),
          throw({fail, [403, StreamName, <<"error_500">>]});
        {error, _} ->
          lager:error("Unabled to connect to api.", []),
          throw({fail, [403, StreamName, <<"api_down">>]})
      end
  end,


  case proplists:get_value(password, Options) of
    RequiredPassword when RequiredPassword =/= undefined ->
      case proplists:get_value("password", Args) of
        RequiredPassword -> ok;
        WrongPassword ->
          lager:error("Publish denied, wrong password: ~p", [WrongPassword]),
          throw({fail, [403, StreamName, <<"wrong_password">>]})
      end;
    undefined -> 
      case proplists:get_value(publish_password, Env) of
        undefined ->
          ok;
        PasswordSpec ->
          [Login,Password] = string:tokens(PasswordSpec, ":"),

          UserLogin = proplists:get_value("login", Args),
          UserPassword = proplists:get_value("password", Args),
          case {UserLogin, UserPassword} of
            {Login, Password} -> 
              ok;
            _ ->
              lager:error("Publish denied, wrong password: ~p, ~p", [UserLogin, UserPassword]),
              throw({fail, [403, StreamName, <<"wrong_login_password">>]})
          end
      end
  end,


  {ok, Recorder} = flu_stream:autostart(StreamName, [{clients_timeout,false},{static,false}|Options]),

  RecordDir = proplists:get_value(path,Options),
  RecordPath = case PublishArgs of
    [<<"record">>|_] when RecordDir =/= undefined ->
      RawName1 = case re:run(RawName, ".flv$") of
        nomatch -> [RawName, ".flv"];
        _ -> RawName
      end,
      iolist_to_binary([RecordDir, "/", RawName1]);
    _ ->
      undefined
  end,


  gen_tracker:setattr(flu_streams, StreamName, []),
  flu_stream:set_source(Recorder, self()),

  lager:info("start recording with flvpath: ~p", [RecordPath]),
  
  {ok, Proxy} = flu_stream:start_helper(StreamName, publish_proxy, {flu_publish_proxy, start_link, [self(), Recorder, [{flv,RecordPath}]]}),
  
  Ref = erlang:monitor(process, Recorder),
  Socket = rtmp_session:get(Session, socket),
  case RecordPath of
    undefined -> lager:info("RTMP publish ~s", [StreamName]);
    _ -> lager:info("RTMP publish ~s record to ~s", [StreamName, RecordPath])
  end,
  
  rtmp_lib:notify_publish_start(Socket, StreamId, 0, Name),
  rtmp_session:set_stream(rtmp_stream:construct([{pid,Proxy},{recording_ref,Ref},{stream_id,StreamId},{started, true}, {recording, true}, {name, Name}]), Session).





no_function(_Session, _AMF) ->
  ?D({unhandled, _AMF}),
  unhandled.
