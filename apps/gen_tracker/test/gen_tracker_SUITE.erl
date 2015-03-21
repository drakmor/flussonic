-module(gen_tracker_SUITE).

-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
  [
    {group, creation}
  ].


groups() ->
  [
    {creation, [], [
      wrong_child_spec,
      temporary,
      transient,
      permanent,
      shutdown
    ]}
  ].


end_per_testcase(_, Config) ->
  case erlang:whereis(test_tracker) of
    undefined -> ok;
    Pid -> 
      erlang:exit(Pid, shutdown),
      timer:sleep(5),
      erlang:exit(Pid, kill)
  end,
  Config.


wrong_child_spec(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {error, _} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, temporary, worker, 200, []}),
  ok.

temporary(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, temporary, 200, worker, []}),
  erlang:monitor(process,Pid),
  [{<<"process1">>, Pid, worker, []}] = gen_tracker:which_children(test_tracker),
  [{<<"process1">>, Pid, worker, []}] = supervisor:which_children(test_tracker),
  Pid ! stop,
  receive {'DOWN', _, _, Pid, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call
  [] = gen_tracker:which_children(test_tracker),
  [] = supervisor:which_children(test_tracker),
  ok.


process1(Parent) ->
  Pid = proc_lib:spawn(fun() ->
    erlang:monitor(process, Parent),
    receive
      invalid_stop -> error(bad_stop);
      stop -> ok
    end
  end),
  {ok, Pid}.



transient(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, transient, 200, worker, []}),
  erlang:monitor(process,Pid),
  [{<<"process1">>, Pid, worker, []}] = gen_tracker:which_children(test_tracker),
  [{<<"process1">>, Pid, worker, []}] = supervisor:which_children(test_tracker),
  Pid ! invalid_stop,
  receive {'DOWN', _, _, Pid, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call

  [{<<"process1">>, Pid2, worker, []}] = gen_tracker:which_children(test_tracker),
  Pid2 =/= Pid orelse error(old_pid),
  erlang:monitor(process,Pid2),

  Pid2 ! stop,
  receive {'DOWN', _, _, Pid2, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call

  [] = gen_tracker:which_children(test_tracker),
  [] = supervisor:which_children(test_tracker),
  ok.





permanent(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, permanent, 200, worker, []}),
  erlang:monitor(process,Pid),
  [{<<"process1">>, Pid, worker, []}] = gen_tracker:which_children(test_tracker),
  [{<<"process1">>, Pid, worker, []}] = supervisor:which_children(test_tracker),
  Pid ! invalid_stop,
  receive {'DOWN', _, _, Pid, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call

  [{<<"process1">>, Pid2, worker, []}] = gen_tracker:which_children(test_tracker),
  Pid2 =/= Pid orelse error(old_pid),
  erlang:monitor(process,Pid2),

  Pid2 ! stop,
  receive {'DOWN', _, _, Pid2, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call


  [{<<"process1">>, Pid3, worker, []}] = gen_tracker:which_children(test_tracker),
  Pid3 ! invalid_stop,
  erlang:monitor(process,Pid3),
  receive {'DOWN', _, _, Pid3, _} -> ok after 100 -> error(timeout_kill) end,


  [{<<"process1">>, Pid4, worker, []}] = gen_tracker:which_children(test_tracker),
  erlang:monitor(process,Pid4),
  supervisor:delete_child(test_tracker, <<"process1">>),
  receive {'DOWN', _, _, Pid4, _} -> ok after 100 -> error(timeout_kill) end,

  [] = gen_tracker:which_children(test_tracker),
  [] = supervisor:which_children(test_tracker),
  ok.



shutdown(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  erlang:monitor(process, G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process2">>, {?MODULE, process1, [self()]}, permanent, 200, worker, []}),
  erlang:monitor(process,Pid),

  erlang:exit(G, shutdown),
  Reason = receive {'DOWN', _, _, G, Reason_} -> Reason_ after 100 -> exit(timeout_shutdown) end,
  shutdown = Reason,
  not erlang:is_process_alive(Pid) orelse error(child_is_alive),
  ok.










