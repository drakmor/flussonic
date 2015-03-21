-module(rtsp_reader).
-author('Max Lapshin <max@maxidoors.ru>').
-include("log.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").
-include("sdp.hrl").
-include_lib("eunit/include/eunit.hrl").


-export([start_link/2, media_info/1]).

-export([init/1, handle_info/2, handle_call/3, terminate/2]).


start_link(URL, Options) ->
  gen_server:start_link(?MODULE, [URL, Options], []).


media_info(RTSP) ->
  gen_server:call(RTSP, media_info, 15000).

-record(rtsp, {
  url,
  rtp_mode,
  queue,
  content_base,
  consumer,
  media_info,
  proto,
  need_refetch = false,
  prefetch_segments = [],
  options
}).

init([URL, Options]) ->
  % {_HostPort, Path} = http_uri2:extract_path_with_query(URL),
  {consumer, Consumer} = lists:keyfind(consumer, 1, Options),
  erlang:monitor(process, Consumer),
  % erlang:send_after(5000, self(), teardown),
  RTPMode = proplists:get_value(rtp, Options, tcp),
  self() ! work,
  Queue = frame_queue:init(5),
  {ok, #rtsp{url = URL, content_base = URL, options = Options, consumer = Consumer, rtp_mode = RTPMode, queue = Queue}}.


handle_info(work, #rtsp{} = RTSP) ->
  RTSP1 = try_read(RTSP),
  {noreply, RTSP1};

handle_info(#video_frame{} = Frame, #rtsp{need_refetch = true, prefetch_segments = Segments1, consumer = Consumer, proto = Proto} = RTSP) ->
  Segments = Segments1 ++ 
  [read_segment(Proto, Seg) || Seg <- list_segments(Proto), lists:keyfind(Seg,1,Segments1) == false],
  [begin
    OpenedAt = dvr_minute:timestamp(Seg),
    Duration = dvr_minute:duration(Seg),
    Gop = #gop{opened_at = OpenedAt, mpegts = Body, duration = Duration},
    Consumer ! Gop
  end|| {Seg, Body} <- Segments],
  handle_info(Frame, RTSP#rtsp{need_refetch = false, prefetch_segments = []});

handle_info(#video_frame{codec = Codec} = Frame, #rtsp{consumer = Consumer, queue = Queue1} = RTSP) when 
  Codec == h264 orelse Codec == aac orelse Codec == mp3 ->
  % #video_frame{content = Content, codec = Codec, flavor = Flavor, dts = DTS, body = Body} = Frame,
  % io:format("~6s ~4s ~10s ~B ~B~n", [Content, Codec, Flavor, round(DTS), size(Body)]),
  Queue2 = case frame_queue:push(Frame, Queue1) of
    {undefined, Q} -> Q;
    {#video_frame{} = Out, Q} ->
  % #video_frame{content = Content, codec = Codec, flavor = Flavor, dts = DTS, body = Body} = Out,
  % io:format("~6s ~4s ~10s ~B ~B~n", [Out#video_frame.content, Out#video_frame.codec, Out#video_frame.flavor, round(Out#video_frame.dts), 
  %   size(Out#video_frame.body)]),
      flu_stream:send_frame(Consumer, Out),
      Q
  end,
  {noreply, RTSP#rtsp{queue = Queue2}};

handle_info(send_rr, #rtsp{proto = Proto} = RTSP) ->
  Proto ! send_rr,
  {noreply, RTSP};

handle_info(keepalive, #rtsp{proto = Proto} = RTSP) ->
  Proto ! keepalive,
  {noreply, RTSP};

handle_info(#video_frame{}, #rtsp{} = RTSP) ->
  {noreply, RTSP};

handle_info({'DOWN', _, _, _,_}, #rtsp{} = RTSP) ->
  {stop, normal, RTSP};

handle_info({response, _Ref, _Code, _Headers, _Body}, #rtsp{} = RTSP) ->
  {noreply, RTSP};

handle_info(teardown, #rtsp{proto = Proto} = RTSP) ->
  rtsp_socket:call(Proto, 'TEARDOWN', []),
  {stop, RTSP, normal};

handle_info({Ref, ok}, #rtsp{} = RTSP) when is_reference(Ref) ->
  {noreply, RTSP}.





handle_call(media_info, _From, #rtsp{media_info = MediaInfo} = RTSP) ->
  {reply, {ok, MediaInfo}, RTSP}.


terminate(_,#rtsp{}) ->
  ok.


try_read(#rtsp{options = Options, url = URL} = RTSP) ->
  try try_read0(RTSP)
  catch
    throw:{rtsp, exit, normal} ->
      throw({stop, normal, RTSP});
    throw:{rtsp, restart, RTSP1} ->
      try_read(RTSP1);
    throw:{rtsp, Error, Reason} ->
      case proplists:get_value(log_error, Options) of
        false -> ok;
        _ -> lager:error("Failed to read from \"~s\": ~p:~240p", [URL, Error, Reason])
      end,
      throw({stop, normal, RTSP})
  end.

try_read0(#rtsp{url = URL, options = Options, rtp_mode = RTPMode} = RTSP) ->
  {ok, Proto} = rtsp_socket:start_link([{consumer, self()}, {url, URL}|Options]),
  unlink(Proto),
  Ref = erlang:monitor(process, Proto),

  {ok, 200, OptionsHeaders, _} = rtsp_socket:call(Proto, 'OPTIONS', []),
  AllowedMethods = [Meth || Meth <- binary:split(proplists:get_value(<<"Public">>, OptionsHeaders, <<>>), [<<",">>,<<" ">>],[global]), Meth =/= <<>>],

  {ok, DescribeCode, DescribeHeaders, SDP} = rtsp_socket:call(Proto, 'DESCRIBE', [{'Accept', <<"application/sdp">>}]),
  DescribeCode == 401 andalso throw({rtsp, denied, 401}),
  DescribeCode == 404 andalso throw({rtsp, not_found, 404}),
  DescribeCode == 200 orelse throw({rtsp, invalid_describe, DescribeCode}),
  ContentBase = parse_content_base(DescribeHeaders, URL, RTSP#rtsp.content_base),

  MI1 = #media_info{streams = Streams1} = sdp:decode(SDP),
  MI2 = MI1#media_info{streams = [S || #stream_info{content = Content, codec = Codec} = S <- Streams1,
    (Content == audio orelse Content == video) andalso Codec =/= undefined]},
  MI3 = case proplists:get_value(tracks, Options) of
    undefined -> MI2;
    TrackIds -> MI2#media_info{streams = [lists:nth(N,MI2#media_info.streams) || N <- TrackIds]}
  end,
  MediaInfo = MI3,
  lists:foldl(fun(#stream_info{options = Opt, track_id = TrackId} = StreamInfo, N) ->
    Control = proplists:get_value(control, Opt),
    Track = control_url(ContentBase, Control),
    Transport = case RTPMode of
      tcp ->
        rtsp_socket:add_channel(Proto, TrackId-1, StreamInfo, tcp),
        io_lib:format("RTP/AVP/TCP;unicast;interleaved=~B-~B", [N, N+1]);
      udp ->
        {ok, {RTPport, RTCPport}} = rtsp_socket:add_channel(Proto, TrackId-1, StreamInfo, udp),
        io_lib:format("RTP/AVP;unicast;client_port=~B-~B", [RTPport, RTCPport])
    end,
    {ok, SetupCode, SetupHeaders, _} = rtsp_socket:call(Proto, 'SETUP', [{'Transport', Transport},{url, Track}]),
    case SetupCode of
      406 when RTPMode == tcp ->
        erlang:demonitor(Ref, [flush]),
        (catch rtsp_socket:stop(Proto)),
        throw({rtsp, restart, RTSP#rtsp{rtp_mode = udp}});
      200 when RTPMode == udp ->
        {match, [RTPPort, RTCPPort]} = re:run(rtsp:header(transport, SetupHeaders), "server_port=(\\d+)-(\\d+)", [{capture,all_but_first,list}]),
        rtsp_socket:connect_channel(Proto, TrackId - 1, list_to_integer(RTPPort), list_to_integer(RTCPPort)),
        ok;
      200 when RTPMode == tcp ->
        ok;
      _ ->
        throw({rtsp, failed_setup, {SetupCode, Track, RTPMode}})
    end,
    N + 2
  end, 0, MediaInfo#media_info.streams),

  {ok, PlayCode, _, _} = rtsp_socket:call(Proto, 'PLAY', [{'Range', <<"npt=0.000-">>}]),
  PlayCode == 200 orelse throw({rtsp, rejected_play, PlayCode}),

  NeedRefetch = lists:member(<<"GET_SEGMENT">>, AllowedMethods),
  % Here we want to fill buffer with all segments but last one,
  % last one is still preparing and we will fetch it after we get first keyframe
  PrefetchSegments = case NeedRefetch of
    true -> [read_segment(Proto, Seg) || Seg <- list_segments(Proto)];
    false -> []
  end,
  RTSP#rtsp{content_base = ContentBase, media_info = MediaInfo, proto = Proto, 
    need_refetch = NeedRefetch, prefetch_segments = PrefetchSegments}.


list_segments(Proto) ->
  case rtsp_socket:call(Proto, 'LIST_SEGMENTS', []) of
    {ok, 200, _, Playlist} ->
      URLs = [Row || <<C,_/binary>> = Row <- binary:split(Playlist, <<"\n">>,[global]), C =/= $#],
      Count = length(URLs),
      if 
        Count =< 4 -> URLs;
        true -> lists:sublist(URLs, Count - 4, 4)
      end;
    {ok, 404, _, _} ->
      []
  end.

read_segment(Proto, Seg) ->
  {ok, 200, _, Body} = rtsp_socket:call(Proto, 'GET_SEGMENT', [{'X-Segment', Seg}]),
  {Seg,Body}.




% Axis cameras have "rtsp://192.168.0.1:554/axis-media/media.amp/trackID=1" in SDP
control_url(_ContentBase, "rtsp://" ++ _ = ControlUrl) -> ControlUrl;
control_url(ContentBase, "/" ++ _ = ControlUrl) ->
  {match, [Host]} = re:run(ContentBase, "(rtsp://[^/]+)/.*", [{capture,all_but_first,list}]),
  Host ++ ControlUrl;
control_url(ContentBase, ControlUrl) ->
  case lists:last(ContentBase) of
    $/ -> ContentBase ++ ControlUrl;
    _ ->
      {ok, {rtsp, Auth, Host, Port, Path, Query}} = http_uri:parse(ContentBase, [{scheme_defaults,[{rtsp,554}]}]),
      URL1 = ["rtsp://", case Auth of
        "" -> "";
        _ -> [Auth, "@"]
      end, Host, case Port of
        554 -> "";
        _ -> [":", integer_to_list(Port)]
      end, filename:dirname(Path), "/", ControlUrl, Query],
      lists:flatten(URL1)
  end.



parse_content_base(Headers, URL, OldContentBase) ->
  case rtsp:header(<<"Content-Base">>, Headers) of
    undefined -> OldContentBase;
    NewContentBase -> % Here we must handle important case when Content-Base is given with local network
      URL1 = case re:run(NewContentBase, "rtsp://([^/]+)(/.*)$", [{capture,all_but_first,list}]) of
        {match, [_Host, BasePath]} ->
          {match, [Host, _Path]} = re:run(URL, "rtsp://([^/]+)(/.*)$", [{capture,all_but_first,list}]),
          "rtsp://" ++ Host ++ BasePath;
        nomatch ->
          case lists:last(URL) of
            $/ -> URL ++ NewContentBase;
            _ -> URL ++ "/" ++ NewContentBase
          end
      end,
      URL2 = re:replace(URL1, "^rtsp://(.+@)?(.*)$", "rtsp://\\2", [{return, list}]),
      case lists:last(URL2) of
        $/ -> URL2;
        _ -> URL2 ++ "/"
      end
  end.




parse_content_base_test_() ->
 [
  ?_assertEqual("rtsp://75.130.113.168:1025/11/", 
    parse_content_base([{'Content-Base', "rtsp://75.130.113.168:1025/11/"}],
      "rtsp://admin:admin@75.130.113.168:1025/11/", "rtsp://admin:admin@75.130.113.168:1025/11/"))
  ,?_assertEqual("rtsp://75.130.113.168:1025/ipcamera/",
    parse_content_base([{'Content-Base', "ipcamera"}],
      "rtsp://admin:admin@75.130.113.168:1025", "rtsp://admin:admin@75.130.113.168:1025"))
 ].


control_url_test_() ->
  [
  ?_assertEqual("rtsp://192.168.0.1:554/axis-media/media.amp/trackID=1", 
    control_url("rtsp://192.168.0.1:554/", "rtsp://192.168.0.1:554/axis-media/media.amp/trackID=1"))
  % ,?_assertEqual("rtsp://192.168.0.1:554/axis-media/media.amp/trackID=1", 
  %   control_url("rtsp://192.168.0.1:554/axis-media/media.amp", "trackID=1"))
  ,?_assertEqual("rtsp://10.15.9.168:8557/PSIA/Streaming/channels/2?videoCodecType=H.264/track1",
    control_url("rtsp://10.15.9.168:8557/PSIA/Streaming/channels/2?videoCodecType=H.264/", "track1"))
  
  ,?_assertEqual("rtsp://192.168.0.1:554/axis-media/media.amp/trackID=1",
    control_url("rtsp://192.168.0.1:554/axis-media/media.amp/", "trackID=1"))
  ,?_assertEqual("rtsp://192.168.0.1:554/axis-media/media.amp/trackID=1",
    control_url("rtsp://192.168.0.1:554/media1/", "/axis-media/media.amp/trackID=1"))
  ,?_assertEqual("rtsp://192.168.0.1/h264/track2?type=h264",
    control_url("rtsp://192.168.0.1/h264/?type=h264", "track2"))
  ].


