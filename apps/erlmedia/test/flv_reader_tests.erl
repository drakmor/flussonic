-module(flv_reader_tests).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-include("../include/video_frame.hrl").
-include("../include/media_info.hrl").



keyframes_test() ->
  {ok, F} = file:open("../../../priv/bunny.flv", [read,binary,raw]),
  {ok, Reader} = flv_reader:init({file,F},[]),
  equal([21,4021,8021,11896,15771,19771,23063,
    27063,31063,35063,39063,43063,47063,
    51063,55063,58105], [T || {T,_Offset} <- flv_reader:keyframes(Reader)]),
  file:close(F).

equal([A|Alist], [A|Blist]) -> equal(Alist, Blist);
equal([], []) -> ok;
equal(Alist, Blist) -> ?assertEqual(Alist, Blist).


mediainfo_test() ->
  {ok, F} = file:open("../../../priv/bunny.flv", [read,binary,raw]),
  {ok, Reader} = flv_reader:init({file,F},[]),
  file:close(F),

  ?assertMatch(#media_info{duration = 59980, flow_type = file, streams = [
    #stream_info{content = video, codec = h264, params = #video_params{width = 240, height = 160}, track_id = 1},
    #stream_info{content = audio, codec = aac, params = #audio_params{sample_rate = 48000}, track_id = 2}
  ]}, flv_reader:media_info(Reader)).



gop_test() ->
  {ok, F} = file:open("../../../priv/bunny.flv", [read,binary,raw]),
  {ok, Reader} = flv_reader:init({file,F},[]),

  {ok, Gop} = flv_reader:read_gop(Reader, 15, undefined),

  Ats = [round(DTS) || #video_frame{dts = DTS, content = audio} <- Gop],
  Vts = [round(DTS) || #video_frame{dts = DTS, content = video} <- Gop],

  ?assertEqual(55063, hd(Vts)),
  ?assertEqual(58063, lists:last(Vts)),

  ?assertEqual(55083, hd(Ats)),
  ?assertEqual(58091, lists:last(Ats)),

  file:close(F),
  ok.
