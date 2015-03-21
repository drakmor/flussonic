%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2012 Max Lapshin
%%% @doc        flu_config
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%%
%%% This file is part of flussonic.
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
-module(flu_config).
-author('Max Lapshin <max@maxidoors.ru>').

-export([load_config/0, parse_routes/1]).
-export([lookup_config/0, parse_config/2]).

-export([set_config/1, get_config/0]).
-include("log.hrl").
-include_lib("eunit/include/eunit.hrl").


set_config(Config) when is_list(Config) ->
  application:set_env(flussonic, config, Config).

get_config() ->
  case application:get_env(flussonic, config) of
    {ok, Config} -> Config;
    undefined -> []
  end.



-spec load_config() -> {ok, Config::list(), Path::file:filename()} | {error, Error::term()}.
load_config() ->
  case lookup_config() of
    {ok, Config1, ConfigPath} ->
      case parse_config(Config1, ConfigPath) of
        {ok, Config2} ->
          {ok, Config2, ConfigPath};
        {error, Error} ->
          {error, Error}
      end;
    {error, Error} ->
      {error, Error}
  end.


-spec lookup_config() -> {ok, Config::list(), Path::file:filename()} | {error, Error::term()}.
lookup_config() ->
  case os:getenv("FLU_CONFIG") of
    false ->
      ConfigPaths = ["priv", "/etc/flussonic", "priv/sample"],
      case file:path_consult(ConfigPaths, "flussonic.conf") of
        {ok, Env1, ConfigPath} ->
          {ok, Env1, ConfigPath};
        {error, Error} ->
          {error, Error}
      end;
    Path ->
      case file:consult(Path) of
        {ok, Env} ->
          {ok, Env, Path};
        {error, Error} ->
          {error, Error}
      end
  end.



parse_config(Config, ConfigPath) -> 
  Env2 = expand_options(load_includes(Config, ConfigPath)),
  {ok, Env2}.




load_includes(Env, ConfigPath) ->
  load_includes(Env, filename:dirname(ConfigPath), []).

load_includes([{include, Wildcard}|Env], Root, Acc) ->
  Files = filelib:wildcard(Wildcard, Root),
  Env1 = lists:foldr(fun(File, Env_) ->
    {ok, SubEnv, _SubPath} = file:path_consult([Root], File),
    SubEnv ++ Env_
  end, Env, Files),
  load_includes(Env1, Root, Acc);

load_includes([Command|Env], Root, Acc) ->
  load_includes(Env, Root, Acc ++ [Command]);

load_includes([], _, Acc) ->
  Acc.


to_b(String) when is_list(String) -> list_to_binary(String);
to_b(Binary) when is_binary(Binary) -> Binary;
to_b(undefined) -> undefined;
to_b(Atom) when is_atom(Atom) -> binary_to_atom(Atom, latin1).

global_keys() -> [sessions,http_auth].

expand_options(Env) ->
  GlobalKeys = global_keys(),
  GlobalOptions = [Entry || Entry <- Env, is_tuple(Entry) andalso lists:member(element(1,Entry),GlobalKeys)],

  [expand_entry(Entry,GlobalOptions) || Entry <- Env].

expand_entry({central, URL},GlobalOptions) -> {central, to_b(URL), GlobalOptions};
expand_entry({central, URL, Options},GlobalOptions) -> {central, to_b(URL), merge(Options,GlobalOptions)};
expand_entry({rewrite, Path, URL},GlobalOptions) -> {stream, to_b(Path), to_b(URL), merge([{static,false}],GlobalOptions)};
expand_entry({rewrite, Path, URL, Options},GlobalOptions) -> {stream, to_b(Path), to_b(URL), merge([{static,false}]++Options,GlobalOptions)};
expand_entry({stream, Path, URL},GlobalOptions) -> {stream, to_b(Path), to_b(URL), merge([{static,true}],GlobalOptions)};
expand_entry({stream, Path, URL, Options},GlobalOptions) -> {stream, to_b(Path), to_b(URL), merge([{static,true}]++Options,GlobalOptions)};
expand_entry({mpegts, Prefix},GlobalOptions) -> {mpegts, to_b(Prefix), merge([{clients_timeout,false}],GlobalOptions)};
expand_entry({mpegts, Prefix, Options},GlobalOptions) -> {mpegts, to_b(Prefix), merge(Options ++ [{clients_timeout,false}],GlobalOptions)};
expand_entry({webm, Prefix},GlobalOptions) -> {webm, to_b(Prefix), merge([{clients_timeout,false}],GlobalOptions)};
expand_entry({webm, Prefix, Options},GlobalOptions) -> {webm, to_b(Prefix), merge(Options ++ [{clients_timeout,false}],GlobalOptions)};
expand_entry({live, Prefix},GlobalOptions) -> {live, to_b(Prefix), merge([{clients_timeout,false}], GlobalOptions)};
expand_entry({live, Prefix, Options},GlobalOptions) -> {live, to_b(Prefix), merge(Options ++ [{clients_timeout,false}],GlobalOptions)};
expand_entry({file, Prefix, Root},GlobalOptions) -> {file, to_b(Prefix), to_b(Root), GlobalOptions};
expand_entry({file, Prefix, Root, Options},GlobalOptions) -> {file, to_b(Prefix), to_b(Root), merge(Options,GlobalOptions)};
expand_entry(api, GlobalOptions) -> {api, GlobalOptions};
expand_entry({api, Options}, GlobalOptions) -> {api, merge(Options,GlobalOptions)};
expand_entry({http_events, URL},_GlobalOptions) -> {flu_event, flu_event_http, [list_to_binary(URL), []]};
expand_entry({plugin, Plugin},_GlobalOptions) -> {plugin, Plugin, []};
expand_entry(Entry,_GlobalOptions) -> Entry.

merge(Opts, Global) ->
  Global1 = lists:foldl(fun(Key,G) ->
    case lists:keyfind(Key,1,Opts) of
      false -> G;
      _ -> lists:keydelete(Key,1,G)
    end
  end, Global, global_keys()),
  optsort(Opts ++ Global1).


optsort(Opts) ->
  lists:usort(fun
    (T1,T2) when is_tuple(T1), is_tuple(T2) -> tuple_to_list(T1) =< tuple_to_list(T2);
    (T1,A2) when is_tuple(T1) -> element(1,T1) =< A2;
    (A1,T2) when is_tuple(T2) -> A1 =< element(1,T2);
    (A1,A2) -> A1 =< A2
  end, Opts).





parse_routes([]) -> [];

parse_routes([{root, Root}|Env]) ->
  Module = case is_escriptized(Root) of
    true -> static_http_escript;
    false -> cowboy_static
  end,
  [
  {"/[...]", Module, [
    {directory,Root},
    {mimetypes, {fun mimetypes:path_to_mimes/2, default}}
  ]}|parse_routes(Env)];


parse_routes([{webm,Prefix,Options}|Env]) ->
  [{<<"/",Prefix/binary, "/[...]">>, webm_handler, [{publish_enabled,true}|Options]}
  |parse_routes(Env)];

parse_routes([{api,Options}|Env]) ->
  api_handler:routes(Options) ++ parse_routes(Env);

parse_routes([{plugin,Plugin,Options}|Env]) ->
  case erlang:module_loaded(Plugin) of
    true -> ok;
    false -> (catch Plugin:module_info())
  end,
  case erlang:function_exported(Plugin, routes, 1) of
    true -> Plugin:routes(Options);
    false -> []
  end ++ parse_routes(Env);

parse_routes([_Else|Env]) ->
  parse_routes(Env).


% tokens(String) ->
%   [cowboy_http:urldecode(Bin, crash) || Bin <- binary:split(String, <<"/">>, [global])].



is_escriptized(Root) ->
  case file:read_file_info(Root) of
    {error, enoent} ->
      case application:get_env(flussonic, escript_files) of
        {ok, _} -> true;
        _ -> false
      end;
    _ ->
      false
  end.




  