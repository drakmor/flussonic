%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2011 Max Lapshin
%%% @doc        Module to write H.264
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
% 
% Two pass method:
% 
% 1. open media
% 2. write header
% 3. read frame by frame, skip pwrite, store info in list
% 4. when eof happens, write frame list to moov
% 5. calculate moov size
% 6. append moov size to all frame offsets
% 7. write again moov to output
% 8. rewind media
% 9. calculate total mdat size
% 10. write total mdat size
% 11. read frame by frame, write frame to output
% 
% 
% One pass method:
% 
% 1. write header
% 2. open file
% 3. remember mdat start position
% 4. wait for frames
% 5. dump frame content to disk, store info in list
% 6. when eof happens, write mdat size into the beginning
% 7. write moov to disk
% 
% So, media writer should be one of two choices should provide two methods:
% 
% Writer(Offset, Bin) — random position write media for one pass method
% or
% Writer(Bin) — stream media for two pass method
% 
%%% This file is part of erlmedia.
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
-module(mp4_writer).
-author('Max Lapshin <max@maxidoors.ru>').
-include("../include/flv.hrl").
-include("../include/mp4.hrl").
-include("../include/mp3.hrl").
-include("../include/aac.hrl").
-include("../include/video_frame.hrl").
-include("../include/media_info.hrl").
-include("log.hrl").

-export([write/2, write/3, pack_language/1, dump_media/1]).
-export([init/2, handle_frame/2, write_frame/2]).
-export([write_frame_list/2]).
-export([pack_durations/1]).
-export([mp4_serialize/1, esds/1]).

-export([pack_compositions/1]).

-record(convertor, {
  method,
  options = [],
  writer,
  url,
  write_offset,
  duration,
  min_dts,
  max_dts,

  audio_frames = [],
  audio_config,

  video_frames = [],
  video_config
}).

-undef(D).
-define(D(X), io:format("~p:~p ~p~n", [?MODULE, ?LINE, X])).

-define(H264_SCALE, 24).
% -define(AUDIO_SCALE, 44.1).


write(InFlvPath, OutMp4Path) ->
  write(InFlvPath, OutMp4Path, []).

write(InFlvPath, OutMp4Path, Options) ->
  {ok, InFlv} = file:open(InFlvPath, [read, binary, {read_ahead, 100000}, raw]),
  {#flv_header{}, ReadOffset} = flv:read_header(InFlv),
  Reader = fun(Key) ->
    flv:read_frame(InFlv, Key)
  end,
  OutMp4 = file:open(OutMp4Path, [write, binary, raw]),
  {ok, Convertor} = init(fun(Offset, Bin) ->
    ok = file:pwrite(OutMp4, Offset, Bin)
  end, Options),
  _Convertor1 = write_mp4(Reader, ReadOffset, Convertor),
  file:close(OutMp4),
  file:close(InFlv),
  ok.


write_frame_list(Frames, Options) ->
  put(buffer, []),
  Writer = fun(_Offset, Bin) ->
    put(buffer, [Bin|get(buffer)])
  end,
  Reader = fun(I) when I =< length(Frames) ->
    (lists:nth(I, Frames))#video_frame{next_id = I+1};
    (_I) -> eof
  end,
  mp4_writer:dump_media([{writer,Writer},{reader,Reader},{start_pos,1}|Options]),
  Output = lists:reverse(get(buffer)),
  put(buffer, undefined),
  {ok, Output}.

% 1294735440 .. 1294736280
%
dump_media(undefined) ->
  {ok, Pid} = media_provider:open(default, "zzz"),
  {ok, Out} = file:open("out.mp4", [append, binary, raw]),
  Start = 1294735443380,
  End = 1294736280000,
  % End = 1294735448480,
  Reader = fun(Pos) ->
    ems_media:read_frame(Pid, Pos)
  end,
  dump_media([{reader, Reader},{writer, fun(_Offset, Bin) ->
    file:write(Out, Bin)
  end}, {from, Start}, {to, End}]),
  file:close(Out),
  ok;

dump_media(Options) ->
  Writer = proplists:get_value(writer, Options),
  Reader = proplists:get_value(reader, Options),
  StartPos = proplists:get_value(start_pos, Options),
    

  put(status, init_mp4_writer),
  {ok, Converter} = mp4_writer:init(Writer, [{method,two_pass}|Options]),
  put(status, dump_pass_1),
  {ok, Converter1} = dump_media_2pass(Reader, Converter, StartPos),
  put(status, write_moov),
  {ok, Converter2} = shift_and_write_moov(Converter1),
  put(status, dump_pass_2),
  {ok, _Converter3} = dump_media_2pass(Reader, Converter2, StartPos),
  ok.


dump_media_2pass(Reader, Writer, Pos) ->
  case Reader(Pos) of
    eof ->
      {ok, Writer};
    [] ->
      {ok, Writer};
    [#video_frame{}|_] = Frames ->
      {Writer1, NewPos} = lists:foldl(fun(#video_frame{next_id = Pos1} = F, {Writer_, _}) ->
        {ok, Writer1_} = handle_frame(F, Writer_),
        {Writer1_, Pos1}
      end, {Writer, Pos}, Frames),
      dump_media_2pass(Reader, Writer1, NewPos);  
    #video_frame{next_id = NewPos} = Frame ->
      % ?D({read, round(Frame#video_frame.dts), Frame#video_frame.flavor, Frame#video_frame.codec}),
      {ok, Writer1} = handle_frame(Frame, Writer),
      dump_media_2pass(Reader, Writer1, NewPos)
  end.

  


write_mp4(Reader, ReadOffset, Convertor) ->
  case handle_frame(Reader(ReadOffset), Convertor) of
    {ok, NextOffset, Convertor1} ->
      write_mp4(Reader, NextOffset, Convertor1);
    {ok, Convertor1} ->
      Convertor1
  end.
      

init(Writer, Options) ->
  Method = proplists:get_value(method, Options),
  % ?D({add_mp4, proplists:get_value(mp4, Options, [])}),
  % ?D({header_end, HeaderEnd}),
  
  Header = mp4_serialize(mp4_header() ++ proplists:get_value(mp4, Options, [])),
  HeaderEnd = iolist_size(Header),
  
  {ok, WriteOffset} = case Method of
    one_pass ->
      {ok, HeaderEnd} = mp4_write(Writer, 0, Header),
      mp4_write(Writer, HeaderEnd, {mdat, <<>>});
    two_pass -> {ok, 0}
  end,
  % ?D({write_offset, WriteOffset}),
  
  {ok, #convertor{options = Options,
             method = Method,
             write_offset = WriteOffset,
             writer = Writer,
             url = proplists:get_value(url, Options, <<>>)}}.
  
  


write_frame(Frame, Writer) ->
  handle_frame(Frame, Writer).
    
handle_frame(#video_frame{flavor = command}, Convertor) ->
  {ok, Convertor};

handle_frame(#video_frame{codec = empty}, Convertor) ->
  {ok, Convertor};

handle_frame(#video_frame{flavor = config} = Frame, #convertor{write_offset = WriteOffset, writer = Writer, method = two_pass2} = Convertor) ->
  Body = flv_video_frame:to_tag(Frame),
  Writer(WriteOffset, Body),
  {ok, Convertor#convertor{write_offset = WriteOffset + iolist_size(Body)}};
    
handle_frame(#video_frame{flavor = config, content = Content, body = Config} = Frame, #convertor{write_offset = WriteOffset} = Convertor) ->
  Convertor1 = case Content of
    audio -> Convertor#convertor{audio_config = Config};
    video -> Convertor#convertor{video_config = Config}
  end,
  Body = flv_video_frame:to_tag(Frame),             
  {ok, Convertor1#convertor{write_offset = WriteOffset + iolist_size(Body)}};

handle_frame(#video_frame{codec = mp3, body = Body}, #convertor{audio_config = undefined} = Convertor) ->
  {ok, #mp3_frame{} = Config, _} = mp3:read(Body),
  % ?D("mp4_writer got audio config"),
  {ok, Convertor#convertor{audio_config = Config}};
  

handle_frame(#video_frame{content = metadata} = Frame, #convertor{write_offset = WriteOffset, writer = Writer, method = two_pass2} = Convertor) ->
  Body = flv_video_frame:to_tag(Frame),
  Writer(WriteOffset, Body),
  {ok, Convertor#convertor{write_offset = WriteOffset + iolist_size(Body)}};
  
handle_frame(#video_frame{content = metadata} = Frame, #convertor{method = two_pass, write_offset = WriteOffset} = Convertor) ->
  Body = flv_video_frame:to_tag(Frame),             
  {ok, Convertor#convertor{write_offset = WriteOffset + iolist_size(Body)}};

handle_frame(#video_frame{} = Frame,
             #convertor{write_offset = WriteOffset, writer = Writer, method = one_pass} = Convertor) ->
  Body = flv_video_frame:to_tag(Frame),             
  Writer(WriteOffset, Body),
  {ok, Convertor1} = append_frame_to_list(Frame, Convertor),
  {ok, Convertor1#convertor{write_offset = WriteOffset + iolist_size(Body)}};

handle_frame(#video_frame{} = Frame,
             #convertor{write_offset = WriteOffset, method = two_pass} = Convertor) ->
  Body = flv_video_frame:to_tag(Frame),             
  {ok, Convertor1} = append_frame_to_list(Frame, Convertor),
  {ok, Convertor1#convertor{write_offset = WriteOffset + iolist_size(Body)}};

handle_frame(#video_frame{} = Frame,
             #convertor{write_offset = WriteOffset, writer = Writer, method = two_pass2} = Convertor) ->
  Body = flv_video_frame:to_tag(Frame),             
  Writer(WriteOffset, Body),
  {ok, Convertor#convertor{write_offset = WriteOffset + iolist_size(Body)}};

handle_frame(eof, #convertor{write_offset = WriteOffset, writer = Writer, method = one_pass} = Convertor) ->
  Writer(0, <<(WriteOffset):32>>),
  {ok, write_moov(sort_frames(Convertor))}.


append_frame_to_list(#video_frame{dts = DTS} = Frame, #convertor{min_dts = Min} = C) when Min == undefined orelse Min > DTS ->
  append_frame_to_list(Frame, C#convertor{min_dts = DTS});

append_frame_to_list(#video_frame{dts = DTS} = Frame, #convertor{max_dts = Max} = C) when Max == undefined orelse Max < DTS ->
  append_frame_to_list(Frame, C#convertor{max_dts = DTS});

append_frame_to_list(#video_frame{body = Body, content = video, codec = Codec} = Frame, 
             #convertor{write_offset = WriteOffset, video_frames = Video} = Convertor) ->
  {ok, Convertor#convertor{video_frames = [Frame#video_frame{body = {WriteOffset + flv:content_offset(Codec),iolist_size(Body)}}|Video]}};

append_frame_to_list(#video_frame{body = Body, content = audio, codec = Codec} = Frame,
             #convertor{write_offset = WriteOffset, audio_frames = Audio} = Convertor) ->
  {ok, Convertor#convertor{audio_frames = [Frame#video_frame{body = {WriteOffset + flv:content_offset(Codec),iolist_size(Body)}}|Audio]}}.


shift_and_write_moov(#convertor{writer = Writer, write_offset = WriteOffset, method = two_pass, options = Options} = Convertor) ->
  MdatSize = WriteOffset,
  Convertor0 = sort_frames(Convertor),
  
  Mp4Header = mp4_header() ++ proplists:get_value(mp4, Options, []),
  Mp4HeaderSize = iolist_size(mp4_serialize(Mp4Header)),
  #convertor{write_offset = MoovSize} = Convertor1 = write_moov(Convertor0#convertor{write_offset = 0, writer = fun(_, _) -> ok end}),
  MdatHeaderSize = 8,
  Convertor2 = append_chunk_offsets(Convertor1, Mp4HeaderSize + MoovSize + MdatHeaderSize),
  
  
  TotalSize = MdatHeaderSize + MdatSize + Mp4HeaderSize + MoovSize,
  case proplists:get_value(header, Options) of
    HeaderWriter when is_function(HeaderWriter) -> HeaderWriter(TotalSize);
    _ -> ok
  end,
  {ok, HeaderEnd} = mp4_write(Writer, 0, Mp4Header),
  Convertor3 = write_moov(Convertor2#convertor{write_offset = HeaderEnd, writer = Writer}),
  
  MoovOffset = Mp4HeaderSize + MoovSize,
  
  Writer(MoovOffset, <<(MdatSize+MdatHeaderSize):32, "mdat">>),
  {ok, Convertor3#convertor{method = two_pass2, write_offset = MoovOffset + MdatHeaderSize}}.
  
  
append_chunk_offsets(#convertor{video_frames = Video, audio_frames = Audio} = Convertor, Shift) ->
  Video1 = [Frame#video_frame{body = {Offset+Shift,Size}} || #video_frame{body = {Offset,Size}} = Frame <- Video],
  Audio1 = [Frame#video_frame{body = {Offset+Shift,Size}} || #video_frame{body = {Offset,Size}} = Frame <- Audio],
  Convertor#convertor{video_frames = Video1, audio_frames = Audio1}.
  
sorted(Frames) ->
  lists:sort(fun
    (#video_frame{dts = DTS1}, #video_frame{dts = DTS2}) when DTS1 >= DTS2 -> true;
    (#video_frame{dts = DTS, pts = PTS1}, #video_frame{dts = DTS, pts = PTS2}) when PTS1 >= PTS2 -> true;
    (_, _) -> false
  end, Frames).
  
sort_frames(#convertor{video_frames = Video, audio_frames = Audio} = Convertor) ->
  Convertor#convertor{video_frames = sorted(Video), audio_frames = sorted(Audio)}.
  
write_moov(#convertor{writer = Writer, write_offset = WriteOffset, min_dts = Min, max_dts = Max} = Convertor) ->
  Duration = round(Max - Min),
  Convertor1 = Convertor#convertor{duration = Duration},
  Moov = {moov, moov(Convertor1)},
  {ok, End} = mp4_write(Writer, WriteOffset, Moov),
  Convertor1#convertor{write_offset = End}.

mp4_header() ->
  [
    {ftyp, [<<"isom", 512:32>>, [<<"isom", "iso2", "avc1", "mp42">>]]},
    {free, <<>>}
  ].

mp4_write(Writer, Offset, [Atom|Atoms])	->
  {ok, NewOffset} = mp4_write(Writer, Offset, Atom),
  mp4_write(Writer, NewOffset, Atoms);

mp4_write(_Writer, Offset, [])	->
  {ok, Offset};
  
mp4_write(Writer, Offset, {_AtomName, _Content} = Atom)	->
  Bin = mp4_serialize(Atom),
  Writer(Offset, Bin),
  {ok, Offset + iolist_size(Bin)}.

mp4_serialize(Bin) when is_binary(Bin) ->
  Bin;
  
mp4_serialize(Number) when is_integer(Number) ->
  <<Number:32>>;
  
mp4_serialize(List) when is_list(List) ->
  mp4_serialize(List, []);
  
mp4_serialize({AtomName, Content}) ->
  Bin = iolist_to_binary(mp4_serialize(Content)),
  % ?D({AtomName, size(Bin) + 8}),
  [<<(size(Bin) + 8):32>>, atom_to_binary(AtomName, latin1), Bin].
  
  
mp4_serialize([], Acc) ->
  lists:reverse(Acc);

mp4_serialize([Atom|List], Acc) ->
  Bin = mp4_serialize(Atom),
  mp4_serialize(List, [Bin | Acc]).

esds(ESDS) -> esds_serialize(ESDS).

esds_serialize(Bin) when is_binary(Bin) ->
  Bin;

esds_serialize(List) when is_list(List) ->
  [esds_serialize(Entry) || Entry <- List];

esds_serialize({TagName, Content}) ->
  Bin = iolist_to_binary(esds_serialize(Content)),
  Tag = case TagName of
    es -> 2;
    es_descr -> 3;
    decoder_config -> 4;
    decoder_specific -> 5;
    sl -> 6;
    _ when is_number(TagName) -> TagName
  end,
  [<<Tag, (size(Bin))>>, Bin].
  

%%%% Content part


tracks(Convertor) ->
  video_track(Convertor) ++ audio_track(Convertor).
  
video_track(#convertor{video_frames = []}) -> [];
video_track(#convertor{video_frames = RevVideo1, url = URL} = Convertor) ->
	CTime = mp4_now(),
	MTime = mp4_now(),
	RevVideo = normalize_h264_durations(RevVideo1),
	Duration = lists:sum([D || #video_frame{dts = D} <- RevVideo]),
  [ {trak, [
    {tkhd, pack_video_tkhd(Convertor)},
    {edts, [
      {elst, [<<0:32>>, pack_elst(Convertor)]}
    ]},
    {mdia, [
      {mdhd, <<0, 0:24, CTime:32, MTime:32, (?H264_SCALE*1000):32, Duration:32, 0:16, 0:16>>},
      {hdlr, <<0:32, 0:32, "vide", 0:96, "VideoHandler", 0>>},
      {minf, [
        {vmhd, <<1:32, 0:16, 0:16, 0:16, 0:16>>},
        {dinf, {dref, [<<0:32, 1:32>>, {'url ', [<<0, 1:24>>, URL]}]}},
        {stbl, [
          {stsd, [<<0:32, 1:32>>, {avc1, pack_video_config(Convertor)}]},
          {stsc, pack_chunk_sizes(RevVideo)},
          {stco, pack_chunk_offsets(RevVideo)},
          {stts, pack_durations(RevVideo)},
          {stsz, pack_sizes(RevVideo)},
          {stss, pack_keyframes(RevVideo)}
        ] ++ case is_ctts_required(RevVideo) of
          true -> [{ctts, pack_compositions(RevVideo)}];
          false -> []
        end}
      ]}
    ]}
  ]}].

% uuid_atom() ->
%   <<16#6b6840f2:32, 16#5f244fc5:32, 16#ba39a51b:32, 16#cf0323f3:32, 0:32>>.

audio_track(#convertor{audio_frames = []}) -> [];
audio_track(#convertor{audio_frames = RevAudio1, audio_config = AAC} = Convertor) ->
  #aac_config{sample_rate = SampleRate} = aac:decode_config(AAC),
  Duration = length(RevAudio1)*1024,
  RevAudio = normalize_aac_durations(RevAudio1),
  [ {trak, [
    {tkhd, pack_audio_tkhd(Convertor)},
    {edts, [
      {elst, [<<0:32>>, pack_elst(Convertor)]}
    ]},
    {mdia, [
      {mdhd, <<0, 0:24, 0:32, 0:32, SampleRate:32, Duration:32, 0:1, (pack_language(eng))/bitstring, 0:16>>},
      {hdlr, <<0:32, 0:32, "soun", 0:96, "SoundHandler", 0>>},
      {minf, [
        {smhd, <<0:32, 0:16, 0:16>>},
        {dinf, {dref, [<<0:32, 1:32>>, {'url ', <<0, 1:24>>}]}},
        {stbl, [
          {stsd, [<<0:32, 1:32>>, pack_audio_config(Convertor)]},
          {stsc, pack_chunk_sizes(RevAudio)},
          {stco, pack_chunk_offsets(RevAudio)},
          {stts, pack_durations(RevAudio)},
          {stsz, pack_sizes(RevAudio)},
          {stss, pack_keyframes(RevAudio)}
        ]}
      ]}
    ]}
  ]}].


normalize_aac_durations(RevAudio) ->
  [F#video_frame{dts = 1024, pts = undefined} || #video_frame{} = F <- RevAudio].


normalize_h264_durations(RevVideo) ->
  Durations1 = lists:reverse(positive(dts_to_durations(RevVideo))),
  % Timescale = ?H264_SCALE*1000,
  % Total = lists:sum(Durations1),
  % Avg = Total / length(Durations1),
  % FPS = round(Timescale / Avg),  
  % Ideal = round(Timescale / FPS),
  % IdealDuration = Ideal*length(Durations1),
  % TotalDeviation = round(abs(Total - IdealDuration)*100 / Total),
  % Deviation = [round(abs(D - Ideal)*100 / Ideal) || D <- Durations1],
  % % ?D({normalize, {time, Total}, {avg, Avg,Timescale}, {avg_abs,Avg*1000 / Timescale}, {fps, FPS, Ideal}, length(Durations1),
  % % {deviation, lists:min(Deviation), lists:max(Deviation)}}),
  % MaxDeviation = lists:max(Deviation),
  % % ?D({normalize, {avg, Avg,MaxDeviation}, {ideal, Ideal, Ideal / Timescale}, {duration,Total},{total,IdealDuration,TotalDeviation}}),
  % Durations2 = if MaxDeviation < 6 andalso TotalDeviation < 5 -> [Ideal || _ <- Durations1];
  %   true -> Durations1
  % end,
  Durations = Durations1,
  lists:zipwith(fun(D, #video_frame{dts = DTS, pts = PTS} = Frame) ->
    Frame#video_frame{dts = D, pts = round((PTS - DTS)*?H264_SCALE)}
  end, Durations, RevVideo).

dts_to_durations(Frames) ->
  dts_to_durations(Frames, []).

% dts_to_durations([#video_frame{dts = DTS1}, #video_frame{dts = DTS2} = F|ReverseFrames], []) when DTS1 > DTS2 ->
%   Duration = round((DTS1 - DTS2)*?H264_SCALE),
%   dts_to_durations([F|ReverseFrames], [Duration, Duration]);
% 

dts_to_durations([#video_frame{}], Acc) ->
  [round(?H264_SCALE) | Acc];

dts_to_durations([#video_frame{dts = DTS, pts = PTS}, #video_frame{dts = DTS1} = F|ReverseFrames], Acc) when DTS =< DTS1->
  dts_to_durations([F#video_frame{dts = DTS, pts = PTS - DTS1 + DTS}|ReverseFrames], [round(?H264_SCALE) | Acc]);

dts_to_durations([#video_frame{dts = DTS1}, #video_frame{dts = DTS2}], Acc) when DTS1 > DTS2 ->
	[round(DTS2*?H264_SCALE), round((DTS1 - DTS2)*?H264_SCALE) | Acc];

dts_to_durations([#video_frame{dts = DTS1}, #video_frame{dts = DTS2} = F|ReverseFrames], Acc) when DTS1 > DTS2 ->
	dts_to_durations([F|ReverseFrames], [round((DTS1 - DTS2)*?H264_SCALE) | Acc]);
	
dts_to_durations(_Frames, _) ->
  % file:write_file("a.dump", erlang:term_to_binary(Frames)),
  erlang:error({invalid_frames}).

positive(Durations) ->
  Good = hd([D || D <- Durations, D > 10]),
  [ if D < 0 -> Good; true -> D end || D <- Durations].



moov(#convertor{} = Convertor) ->
  [ {mvhd, pack_mvhd(Convertor)} ] ++ tracks(Convertor).

mp4_now() ->
  calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - 
  calendar:datetime_to_gregorian_seconds({{1904,1,1},{0,0,0}}).


pack_language(Lang) when is_binary(Lang) ->
  pack_language(binary_to_list(Lang));

pack_language(Lang) when is_atom(Lang) ->
  pack_language(atom_to_list(Lang));

pack_language([L1, L2, L3]) ->
  <<(L1 - 16#60):5, (L2 - 16#60):5, (L3 - 16#60):5>>.
  
pack_elst(#convertor{duration = Duration}) ->
  MediaTime = 0, 
  MediaRate = 1,
  MediaFrac = 0,
  <<1:32, Duration:32, MediaTime:32, MediaRate:16, MediaFrac:16>>.

pack_chunk_sizes(_VChunks) ->
  <<0:32, 1:32, 1:32, 1:32, 1:32>>.
 
pack_chunk_offsets(VChunks) ->
  [<<0:32, (length(VChunks)):32>>, [<<Offset:32>> || #video_frame{body = {Offset,_}} <- lists:reverse(VChunks)]].
 

next_track_id(#convertor{video_frames = []}) -> 2;
next_track_id(#convertor{audio_frames = []}) -> 2;
next_track_id(_) -> 3.


pack_mvhd(#convertor{duration = Duration} = Convertor) ->
  CTime = mp4_now(),
  MTime = CTime,
  TimeScale = 1000,
  Rate = 1,
  RateDelim = 0,
  Volume = 1,
  VolumeDelim = 0,
  Reserved1 = 0,
  Matrix = <<0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,64,0,0,0>>,
  Reserved2 = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
  NextTrackId = next_track_id(Convertor),
  <<0:32, CTime:32, MTime:32, TimeScale:32, Duration:32, Rate:16, RateDelim:16,
        Volume, VolumeDelim, 0:16, Reserved1:64, Matrix:36/binary, Reserved2:24/binary, NextTrackId:32>>.



pack_video_tkhd(Convertor) -> pack_tkhd(Convertor, video).
pack_audio_tkhd(Convertor) -> pack_tkhd(Convertor, audio).

pack_tkhd(#convertor{duration = Duration, video_config = Config}, Track) ->
	Flags = 15,
	CTime = mp4_now(),
	MTime = mp4_now(),
	TrackID = case Track of
	  video -> 1;
	  audio -> 2
	end,
	Reserved1 = 0,
	Reserved2 = 0,
	Layer = 0,
	AlternateGroup = 0,
	Volume = case Track of
	  video -> 0;
	  audio -> 1
	end,
	VolDelim = 0,
  Reserved3 = 0,
  Matrix = <<0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,64,0,0,0>>,
  
  
  {Width, Height} = case Track of
    video ->
      Meta = h264:metadata(Config),
      {proplists:get_value(width, Meta), proplists:get_value(height, Meta)};
    audio ->
      {0, 0}
  end,
  
  WidthDelim = 0,
  HeightDelim = 0,
  <<0, Flags:24, CTime:32, MTime:32, TrackID:32, Reserved1:32, Duration:32, Reserved2:64, 
  Layer:16, AlternateGroup:16, Volume, VolDelim, Reserved3:16, Matrix/binary, 
  Width:16, WidthDelim:16, Height:16, HeightDelim:16>>.

pack_audio_config(#convertor{audio_config = undefined, audio_frames = [#video_frame{codec = speex}|_]}) ->
  {'spx ', <<>>};

pack_audio_config(#convertor{audio_config = undefined}) ->
  ?D({"no audio config"}),
  <<>>;


pack_audio_config(#convertor{audio_config = Config, audio_frames = [#video_frame{codec = Codec}|_]}) ->
  Reserved = <<0,0,0,0,0,0>>,
  RefIndex = 1,
  SoundVersion = 0,
  Unknown = <<0,0,0,0,0,0>>,

  {ObjectType, ChannelsCount, SampleRate} = case Codec of
    aac ->
      #aac_config{channel_count = AACChannels, sample_rate = SR} = aac:decode_config(Config),
      {64, AACChannels, SR};
    mp3 ->
      #mp3_frame{channels = Channels, sample_rate = SR} = Config,
      {107, Channels, SR}
  end,

  
  SampleSize = 16,
  PacketSize = 0,
  % SampleRate = 44100,
  CompressionId = 0,

  ESID = 2,
  StreamDependence = 0,
  HaveUrl = 0,
  OCRStream = 0,
  StreamPriority = 0,
  ESDescr = <<ESID:16, StreamDependence:1, HaveUrl:1, OCRStream:1, StreamPriority:5>>,
  
  StreamType = 5,
  UpStream = 0,
  Reserved3 = 1,
  BufferSizeDB = 0,
  MaxBitrate = 126035,
  AvgBitrate = 0,
  ConfigDescr = <<ObjectType, StreamType:6, UpStream:1, Reserved3:1, BufferSizeDB:24, MaxBitrate:32, AvgBitrate:32>>,
  

  MP4A = <<Reserved:6/binary, RefIndex:16, SoundVersion:16, Unknown:6/binary, ChannelsCount:16, SampleSize:16, 
            CompressionId:16, PacketSize:16, SampleRate:16, 0:16>>,
            
  DescrTag = case Codec of
    aac -> [ConfigDescr, {decoder_specific, Config}];
    mp3 -> ConfigDescr
  end,
  ESDS = {es_descr, [ESDescr,
     {decoder_config, DescrTag},
     {sl, <<2>>}]
   },
   
  {mp4a, [MP4A,{esds, [<<0:32>>, esds_serialize(ESDS)]}]}.




pack_video_config(#convertor{video_config = Config}) ->
  Meta = h264:metadata(Config),
  Width = proplists:get_value(width, Meta),
  Height = proplists:get_value(height, Meta),
  
  Reserved = <<0,0,0,0,0,0>>,
  RefIndex = 1,
  CodecStreamVersion = 0,
  CodecStreamRevision = 0,
  HorizRes = 72,
  VertRes = 72,
  DataSize = 0,
  FrameCount = 1,
  Compressor = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
  Reserved1 = 24,
  Reserved2 = 16#FFFF,
  Bin = <<Reserved:6/binary, RefIndex:16, CodecStreamVersion:16, CodecStreamRevision:16, 
        0:32, 0:32, 0:32, Width:16, Height:16,
        HorizRes:16, 0:16, VertRes:16, 0:16, DataSize:32, FrameCount:16, 
        (size(Compressor)), Compressor:31/binary,
        Reserved1:16, Reserved2:16>>,
  
  [Bin, {avcC, Config}].

pack_durations([]) ->	
  <<0:32, 0:32>>;
  
pack_durations(ReverseFrames) ->
	Durations1 = lists:reverse([D || #video_frame{dts = D} <- ReverseFrames]),
  % Durations2 = normalize_durations(Durations1, Content),
	Durations = Durations1,
	
  List1 = collapse_durations(Durations),
  List = [<<Count:32, Duration:32>> || {Count,Duration} <- List1],
	[<<0:32, (length(List)):32>>, List].

collapse_durations([Duration|Durations]) ->
  collapse_durations(Durations, 1, Duration, []).

collapse_durations([], Count, Duration, Acc) ->
  lists:reverse([{Count,Duration}|Acc]);
  
collapse_durations([Duration|Durations], Count, Duration, Acc) ->
  collapse_durations(Durations, Count + 1, Duration, Acc);

collapse_durations([NewDuration|Durations], Count, Duration, Acc) ->
  collapse_durations(Durations, 1, NewDuration, [{Count,Duration}|Acc]).

pack_sizes(ReverseFrames) ->
  pack_sizes(<<0:32, 0:32, (length(ReverseFrames)):32>>, lists:reverse(ReverseFrames)).

pack_sizes(Bin, []) ->
  Bin;
  
pack_sizes(Bin, [#video_frame{body = {_Offset,BodySize}}|Frames]) ->
  pack_sizes(<<Bin/binary, BodySize:32>>, Frames).


pack_keyframes(ReverseFrames) ->
  List = pack_keyframes(lists:reverse(ReverseFrames), [], 1),
  [<<0:32, (length(List)):32>>, [<<Number:32>> || Number <- List]].
  
pack_keyframes([#video_frame{flavor = keyframe}|Frames], Acc, Number) ->
  pack_keyframes(Frames, [Number|Acc], Number + 1);

pack_keyframes([#video_frame{}|Frames], Acc, Number) ->
  pack_keyframes(Frames, Acc, Number + 1);
  
pack_keyframes([], Acc, _) ->
  lists:reverse(Acc).


is_ctts_required(ReverseFrames) ->
  length([true || #video_frame{dts = DTS, pts = PTS} <- ReverseFrames, PTS - DTS > 1]) > 0.

pack_compositions(ReverseFrames) ->
  [<<0:32, (length(ReverseFrames)):32>>, compositions(ReverseFrames, [])].
  
  
compositions([], Acc) ->
  Acc;
% Here already PTS - DTS * Scale is stored  
compositions([#video_frame{pts = PTS}|Frames], Acc) ->
  compositions(Frames, [<<1:32, PTS:32>>|Acc]).

%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").

esds_serialize_test_() ->
  [?_assertEqual(<<5,1,2>>, iolist_to_binary(esds_serialize({decoder_specific, <<2>>}))),
  ?_assertEqual(<<3,6,0,0,0,5,1,2>>, iolist_to_binary(esds_serialize({es_descr, [<<0,0>>, <<0>>, {decoder_specific, <<2>>}]})))].

mp4_serialize1_test_() ->
  [?_assertEqual(<<8:32, "free">>, iolist_to_binary(mp4_serialize({free, <<>>}))),
  ?_assertEqual(<<16:32, "ftyp", "isom", "mp42">>, iolist_to_binary(mp4_serialize({ftyp, [<<"isom">>, <<"mp42">>]}))),
  ?_assertEqual(<<16:32, "ftyp", 5:32, 100:32>>, iolist_to_binary(mp4_serialize({ftyp, [5, 100]})))].

pack_durations_test() ->
  Frames = [
    #video_frame{dts = 4, content = video},
    #video_frame{dts = 4, content = video},
    #video_frame{dts = 2, content = video}
  ],
  ?assertEqual(<<0:32, 2:32, 1:32, 2:32, 2:32, 4:32>>, iolist_to_binary(pack_durations(Frames))).

% pack_glue_durations_test() ->
%   Frames = [#video_frame{dts = 2, pts = 2, content = video}, #video_frame{dts = 2, pts = 1, content = video}, #video_frame{dts = 0, pts = 0, content = video}],
%   ?assertEqual(<<0:32, 3:32, 1:32, 24:32, 1:32, 24:32, 1:32, 24:32>>, iolist_to_binary(pack_durations(Frames))).


pack_keyframes_test() ->
  Frames = [#video_frame{}, #video_frame{}, #video_frame{flavor = keyframe}, #video_frame{}, #video_frame{flavor = keyframe}],
  ?assertEqual(<<0:32, 2:32, 1:32, 3:32>>, iolist_to_binary(pack_keyframes(Frames))).
  
