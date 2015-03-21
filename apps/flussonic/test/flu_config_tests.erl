-module(flu_config_tests).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").




expand_entry_test_() ->
  [?_assertEqual({ok, [{stream, <<"stream1">>, <<"fake://stream1">>, [{static,false}]}]},
      flu_config:parse_config([{rewrite, "stream1", "fake://stream1"}], undefined)),
  ?_assertEqual({ok, [{stream, <<"stream1">>, <<"fake://stream1">>, [{dvr,"root"},{static,false}]}]},
      flu_config:parse_config([{rewrite, "stream1", "fake://stream1", [{dvr,"root"}]}], undefined)),


  ?_assertEqual({ok, [
    {stream, <<"stream1">>, <<"fake://stream1">>, [{dvr,"root"},{sessions,false},{static,false}]},
    {sessions,false},
    {stream, <<"stream2">>, <<"fake://stream1">>, [{dvr,"root"},{sessions,false},{static,false}]}
  ]},
  flu_config:parse_config([
    {rewrite, "stream1", "fake://stream1", [{dvr,"root"}]},
    {sessions,false},
    {rewrite, "stream2", "fake://stream1", [{dvr,"root"}]}
  ], undefined)),

  ?_assertEqual({ok, [
    {sessions, "http://1/"},
    {stream, <<"stream1">>, <<"passive">>, [{sessions, "http://2/"},{static,true}]}
  ]}, 
  flu_config:parse_config([
    {sessions, "http://1/"},
    {stream, <<"stream1">>, <<"passive">>, [{sessions, "http://2/"}]}
  ], undefined)),

  ?_assertEqual({ok, [{central, <<"http://central/">>, []}]},
      flu_config:parse_config([{central, "http://central/"}], undefined)),

  ?_assertEqual({ok, [{central, <<"http://central/">>, [{opt1,val1}]}]},
      flu_config:parse_config([{central, "http://central/", [{opt1,val1}]}], undefined)),

  ?_assertEqual({ok, [{stream, <<"stream1">>, <<"fake://stream1">>, [{static,true}]}]},
      flu_config:parse_config([{stream, "stream1", "fake://stream1"}], undefined)),
  ?_assertEqual({ok, [{stream, <<"stream1">>, <<"fake://stream1">>, [{dvr,"root"},{static,true}]}]},
      flu_config:parse_config([{stream, "stream1", "fake://stream1", [{dvr,"root"}]}], undefined)),

  ?_assertEqual({ok, [{mpegts, <<"stream">>, [{clients_timeout,false}]}]},
      flu_config:parse_config([{mpegts, "stream"}], undefined)),
  ?_assertEqual({ok, [{mpegts, <<"stream">>, [{clients_timeout,false},{sessions, "http://host"}]}]},
      flu_config:parse_config([{mpegts, "stream", [{sessions, "http://host"}]}], undefined)),

  ?_assertEqual({ok, [{live, <<"live">>, [{clients_timeout,false}]}]},
      flu_config:parse_config([{live, "live"}], undefined)),
  ?_assertEqual({ok, [{live, <<"live">>, [{clients_timeout,false},{sessions, "http://host"}]}]},
      flu_config:parse_config([{live, "live", [{sessions, "http://host"}]}], undefined)),

  ?_assertEqual({ok, [{live, <<"live">>, [{clients_timeout,false}, publish_enabled, {push, "http://a"},{push, "http://b"}] }]},
    flu_config:parse_config([{live, "live", [{push, "http://b"},{push,"http://a"},publish_enabled]}], undefined)),


  ?_assertEqual({ok, [{file, <<"vod">>, <<"/movies">>, []}]}, 
      flu_config:parse_config([{file, "vod", "/movies"}], undefined)),
  ?_assertEqual({ok, [{file, <<"vod">>, <<"/movies">>, [{sessions, "http://ya.ru/"}]}]}, 
      flu_config:parse_config([{file, "vod", "/movies", [{sessions, "http://ya.ru/"}]}], undefined)),

  ?_assertEqual({ok, [{api, []}]}, 
    flu_config:parse_config([api], undefined)),
  ?_assertEqual({ok, [{api, [{pass,"admin","passw"}]}]}, 
    flu_config:parse_config([{api,[{pass,"admin","passw"}]}], undefined)),

  ?_assertEqual({ok, [{api, [{http_auth,"user", "zzz"}]},{http_auth,"user", "zzz"}]},
    flu_config:parse_config([api,{http_auth,"user", "zzz"}], undefined)),
  ?_assertEqual({ok, [{api, [{http_auth,"user", "zzz"},{pass,"admin","passw"}]},{http_auth,"user", "zzz"}]}, 
    flu_config:parse_config([{api,[{pass,"admin","passw"}]},{http_auth,"user", "zzz"}], undefined)),


  ?_assertEqual({ok, [{flu_event, flu_event_http, [<<"http://ya.ru/">>, []]}]}, 
    flu_config:parse_config([{http_events, "http://ya.ru/"}], undefined)),


  ?_assertEqual({ok, [{plugin, iptv, []}]}, 
    flu_config:parse_config([{plugin, iptv}], undefined)),
  ?_assertEqual({ok, [{plugin, iptv, [{cas,none}]}]}, 
    flu_config:parse_config([{plugin, iptv, [{cas,none}]}], undefined))
  ].

global_sessions_test_() ->
  [?_assertEqual({ok, [{stream, <<"stream1">>, <<"fake://stream1">>, [{sessions,"http://ya.ru"},{static,true}]},{sessions,"http://ya.ru"}]},
      flu_config:parse_config([{stream, "stream1", "fake://stream1"},{sessions, "http://ya.ru"}], undefined)),
  ?_assertEqual({ok, [{live, <<"live">>, [{clients_timeout,false},{sessions, "http://ya.ru"}]}, {sessions,"http://ya.ru"}]},
      flu_config:parse_config([{live, "live"}, {sessions, "http://ya.ru"}], undefined)),
  ?_assertEqual({ok, [{file, <<"vod">>, <<"/movies">>, [{sessions, "http://ya.ru/"}]}, {sessions,"http://ya.ru/"}]}, 
      flu_config:parse_config([{file, "vod", "/movies"}, {sessions, "http://ya.ru/"}], undefined))
  ].




plugin_route_test_() ->
  {setup,
  fun() ->
    meck:new(fake_plugin),
    meck:expect(fake_plugin, routes, fun(_) -> 
      [{<<"/plugin/api/[...]">>, plugin_api, []}]
    end),
    ok
  end,
  fun(_) ->
      meck:unload(fake_plugin)
  end,
  [
  fun() ->
    ?assertMatch([{<<"/plugin/api/[...]">>, plugin_api, []}], 
      flu_config:parse_routes([{plugin, fake_plugin, []}]))
  end
  ]
  }.

