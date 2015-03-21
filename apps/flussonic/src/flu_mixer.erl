-module(flu_mixer).
-author('Max Lapshin <max@maxidoors.ru>').
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").
-include("log.hrl").

-export([read/3]).
-export([start_link/3]).
-export([init/1, handle_call/3, handle_info/2, terminate/2]).


read(Stream, <<"mixer://", URL/binary>>, _Options) ->
  [Video, Audio] = binary:split(URL, <<",">>),
  {ok, Proxy} = flu_stream:start_helper(Stream, mixer, {flu_mixer, start_link, [Video, Audio, self()]}),
  {ok, MediaInfo} = gen_server:call(Proxy, start),
  {ok, Proxy, MediaInfo}.



start_link(VideoName, AudioName, Consumer) ->
  gen_server:start_link(?MODULE, [VideoName, AudioName, Consumer], []).

-define(BUFFER, 5).

-record(mixer, {
  video_name,
  video,
  video_dts,
  audio_name,
  audio,
  audio_shift,

  last_dts,
  consumer,
  media_info,
  queue
}).

init([VideoName, AudioName, Consumer]) ->
  erlang:monitor(process, Consumer),
  {ok, #mixer{video_name = VideoName, audio_name = AudioName, consumer = Consumer, queue = frame_queue:init(5)}}.


media_info(Stream) ->
  media_info(Stream, 10).

media_info(_Stream, 0) -> undefined;
media_info(Stream, Retries) ->
  case flu_stream:media_info(Stream) of
    undefined ->
      timer:sleep(500),
      media_info(Stream, Retries - 1);
    #media_info{} = MI ->
      MI
  end.


round_(undefined) -> -1;
round_(A) -> round(A).

max_(D1, undefined) -> D1;
max_(D1, D2) when D1 - D2 >= 0 -> D1;
max_(D1, D2) when D2 - D1 > 0 -> D2.

handle_call(start, _From, #mixer{video = undefined, video_name = VideoName,
  audio = undefined, audio_name = AudioName} = Mixer) ->

  {ok, Video} = flu_stream:autostart(VideoName),
  flu_stream:subscribe(Video,[]),
  erlang:monitor(process, Video),

  {ok, Audio} = flu_stream:autostart(AudioName),
  erlang:monitor(process, Audio),
  flu_stream:subscribe(Audio,[]),

  VideoMI = #media_info{streams = VideoStreams} = media_info(VideoName),
  _AudioMI= #media_info{streams = AudioStreams} = media_info(AudioName),

  VideoStream = (hd([Stream || #stream_info{content = video} = Stream <- VideoStreams]))#stream_info{track_id = 1},
  AudioStream = (hd([Stream || #stream_info{content = audio} = Stream <- AudioStreams]))#stream_info{track_id = 2},

  MediaInfo = VideoMI#media_info{streams = [VideoStream, AudioStream]},
  {reply, {ok, MediaInfo}, Mixer#mixer{video = Video, audio = Audio, media_info = MediaInfo}};

handle_call(Call, _From, #mixer{} = Mixer) ->
  {reply, {error, {unknown_call, Call}}, Mixer}.


handle_info(#video_frame{content = video, stream_id = Video, dts = DTS} = Frame, 
  #mixer{video = Video, video_dts = undefined} = Mixer) ->
  lager:info("sync video (~B)", [round_(DTS)]),
  handle_info(Frame, Mixer#mixer{video_dts = DTS, last_dts = DTS});

handle_info(#video_frame{content = video, stream_id = Video, dts = DTS} = Frame,
  #mixer{video = Video, video_dts = VDTS} = Mixer) when abs(VDTS - DTS) > 1000 ->
  lager:info("video stream unsynced: ~B vs ~B", [round_(DTS), round_(VDTS)]),
  handle_info(Frame, Mixer#mixer{video_dts = undefined, audio_shift = undefined, last_dts = undefined});

handle_info(#video_frame{content = video, stream_id = Video, dts = DTS} = Frame, 
  #mixer{video = Video, consumer = Consumer, queue = Buf, last_dts = LastDTS} = Mixer) ->
  {F, Buf1} = frame_queue:push(Frame#video_frame{stream_id = 1, track_id = 1}, Buf),
  case F of
    undefined -> ok;
    _ -> flu_stream:send_frame(Consumer, F)
  end,
  % if LastDTS > DTS ->
  %   ?DBG("delayed frame video ~B/~B", [round_(DTS), round_(LastDTS)]);
  % true -> ok end,
  % ?D({video, round(Frame#video_frame.dts)}),
  {noreply, Mixer#mixer{last_dts = max_(DTS,LastDTS), video_dts = DTS, queue = Buf1}};

handle_info(#video_frame{content = metadata, stream_id = Video} = Frame, #mixer{video = Video, consumer = Consumer} = Mixer) ->
  Consumer ! Frame#video_frame{stream_id = 1, track_id = 0},
  {noreply, Mixer};

handle_info(#video_frame{content = audio, stream_id = Audio, dts = DTS} = Frame, 
  #mixer{audio = Audio, video_dts = VDTS, audio_shift = undefined} = Mixer) when VDTS =/= undefined ->
  lager:info("sync audio (~B) on video (~B)", [round_(DTS), round_(VDTS)]),
  handle_info(Frame, Mixer#mixer{audio_shift = VDTS - DTS});

handle_info(#video_frame{content = audio, stream_id = Audio, dts = ADTS} = Frame,
  #mixer{audio = Audio, audio_shift = Delta, video_dts = VDTS} = Mixer) when abs(ADTS + Delta - VDTS) > 1000 ->
  lager:info("audio stream unsynced: A:~B, V:~B", [round_(ADTS + Delta), round_(VDTS)]),
  handle_info(Frame, Mixer#mixer{audio_shift = undefined});

handle_info(#video_frame{content = audio, stream_id = Audio, dts = DTS, pts = PTS} = Frame, 
  #mixer{audio = Audio, audio_shift = Delta, consumer = Consumer, last_dts = LastDTS, queue = Buf} = Mixer) when Delta =/= undefined->
  % if LastDTS > DTS ->
  %   ?DBG("delayed frame audio ~B/~B", [round_(DTS + Delta), round_(LastDTS)]);
  % true -> ok end,
  {F, Buf1} = frame_queue:push(Frame#video_frame{dts = DTS + Delta, pts = PTS + Delta, stream_id = 1, track_id = 2}, Buf),
  case F of
    undefined -> ok;
    _ -> flu_stream:send_frame(Consumer, F)
  end,
  % ?D({audio, round(DTS+Delta)}),
  {noreply, Mixer#mixer{last_dts = max_(DTS, LastDTS), queue = Buf1}};

handle_info(#video_frame{} = _Frame, #mixer{} = Mixer) ->
  {noreply, Mixer};

handle_info(#media_info{}, #mixer{} = Mixer) ->
  %FIXME properly handle MI update
  {noreply, Mixer};

handle_info(Info, Mixer) ->
  {stop, {unknown_message, Info}, Mixer}.



terminate(_,_) -> ok.





