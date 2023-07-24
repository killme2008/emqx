%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_mgmt_api_configs_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_mgmt_api_test_util:init_suite([emqx_conf]),
    Config.

end_per_suite(_) ->
    emqx_mgmt_api_test_util:end_suite([emqx_conf]).

init_per_testcase(TestCase = t_configs_node, Config) ->
    ?MODULE:TestCase({'init', Config});
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(TestCase = t_configs_node, Config) ->
    ?MODULE:TestCase({'end', Config});
end_per_testcase(_TestCase, Config) ->
    Config.

t_get_with_json(_Config) ->
    {ok, Configs} = get_configs_with_json(),
    maps:map(
        fun(Name, Value) ->
            {ok, Config} = get_config(Name),
            ?assertEqual(Value, Config)
        end,
        maps:remove(<<"license">>, Configs)
    ),
    ok.

t_update(_Config) ->
    %% update ok
    {ok, SysMon} = get_config(<<"sysmon">>),
    #{<<"vm">> := #{<<"busy_port">> := BusyPort}} = SysMon,
    NewSysMon = #{<<"vm">> => #{<<"busy_port">> => not BusyPort}},
    {ok, #{}} = update_config(<<"sysmon">>, NewSysMon),
    {ok, SysMon1} = get_config(<<"sysmon">>),
    #{<<"vm">> := #{<<"busy_port">> := BusyPort1}} = SysMon1,
    ?assertEqual(BusyPort, not BusyPort1),
    assert_busy_port(BusyPort1),
    %% Make sure the override config is updated, and remove the default value.
    ?assertMatch(
        #{<<"vm">> := #{<<"busy_port">> := BusyPort1}},
        maps:get(<<"sysmon">>, emqx_config:read_override_conf(#{override_to => cluster}))
    ),

    %% update failed
    ErrorSysMon = emqx_utils_maps:deep_put([<<"vm">>, <<"busy_port">>], SysMon, "123"),
    ?assertMatch(
        {error, {"HTTP/1.1", 400, _}},
        update_config(<<"sysmon">>, ErrorSysMon)
    ),
    {ok, SysMon2} = get_config(<<"sysmon">>),
    ?assertEqual(SysMon1, SysMon2),

    %% reset specific config
    ok = reset_config(<<"sysmon">>, "conf_path=vm.busy_port"),
    {ok, SysMon3} = get_config(<<"sysmon">>),
    ?assertMatch(#{<<"vm">> := #{<<"busy_port">> := true}}, SysMon3),
    assert_busy_port(true),

    %% reset no_default_value config
    NewSysMon1 = emqx_utils_maps:deep_put([<<"vm">>, <<"busy_port">>], SysMon, false),
    {ok, #{}} = update_config(<<"sysmon">>, NewSysMon1),
    ?assertMatch({error, {"HTTP/1.1", 400, _}}, reset_config(<<"sysmon">>, "")),
    {ok, SysMon4} = get_config(<<"sysmon">>),
    ?assertMatch(#{<<"vm">> := #{<<"busy_port">> := false}}, SysMon4),
    ok.

assert_busy_port(BusyPort) ->
    {_Pid, Monitors} = erlang:system_monitor(),
    RealBusyPort = proplists:get_value(busy_port, Monitors, false),
    ?assertEqual(BusyPort, RealBusyPort).

t_log(_Config) ->
    {ok, Log} = get_config("log"),
    File = "log/emqx-test.log",
    %% update handler
    Log1 = emqx_utils_maps:deep_put([<<"file">>, <<"default">>, <<"enable">>], Log, true),
    Log2 = emqx_utils_maps:deep_put([<<"file">>, <<"default">>, <<"path">>], Log1, File),
    {ok, #{}} = update_config(<<"log">>, Log2),
    {ok, Log3} = logger:get_handler_config(default),
    ?assertMatch(#{config := #{file := File}}, Log3),
    ErrLog1 = emqx_utils_maps:deep_put([<<"file">>, <<"default">>, <<"enable">>], Log, 1),
    ?assertMatch({error, {"HTTP/1.1", 400, _}}, update_config(<<"log">>, ErrLog1)),
    ErrLog2 = emqx_utils_maps:deep_put(
        [<<"file">>, <<"default">>, <<"enabfe">>], Log, true
    ),
    ?assertMatch({error, {"HTTP/1.1", 400, _}}, update_config(<<"log">>, ErrLog2)),

    %% add new handler
    File1 = "log/emqx-test1.log",
    Handler = emqx_utils_maps:deep_get([<<"file">>, <<"default">>], Log2),
    NewLog1 = emqx_utils_maps:deep_put([<<"file">>, <<"new">>], Log2, Handler),
    NewLog2 = emqx_utils_maps:deep_put(
        [<<"file">>, <<"new">>, <<"path">>], NewLog1, File1
    ),
    {ok, #{}} = update_config(<<"log">>, NewLog2),
    {ok, Log4} = logger:get_handler_config(new),
    ?assertMatch(#{config := #{file := File1}}, Log4),

    %% disable new handler
    Disable = emqx_utils_maps:deep_put(
        [<<"file">>, <<"new">>, <<"enable">>], NewLog2, false
    ),
    {ok, #{}} = update_config(<<"log">>, Disable),
    ?assertEqual({error, {not_found, new}}, logger:get_handler_config(new)),
    ok.

t_global_zone(_Config) ->
    {ok, Zones} = get_global_zone(),
    ZonesKeys = lists:map(
        fun({K, _}) -> list_to_binary(K) end, emqx_zone_schema:global_zone_with_default()
    ),
    ?assertEqual(lists:usort(ZonesKeys), lists:usort(maps:keys(Zones))),
    ?assertEqual(
        emqx_config:get_zone_conf(default, [mqtt, max_qos_allowed]),
        emqx_utils_maps:deep_get([<<"mqtt">>, <<"max_qos_allowed">>], Zones)
    ),
    ?assertError(
        {config_not_found, [zones, no_default, mqtt, max_qos_allowed]},
        emqx_config:get_zone_conf(no_default, [mqtt, max_qos_allowed])
    ),

    NewZones1 = emqx_utils_maps:deep_put([<<"mqtt">>, <<"max_qos_allowed">>], Zones, 1),
    NewZones2 = emqx_utils_maps:deep_remove([<<"mqtt">>, <<"peer_cert_as_clientid">>], NewZones1),
    {ok, #{<<"mqtt">> := Res}} = update_global_zone(NewZones2),
    %% Make sure peer_cert_as_clientid is not removed(fill default)
    ?assertMatch(
        #{
            <<"max_qos_allowed">> := 1,
            <<"peer_cert_as_clientid">> := <<"disabled">>
        },
        Res
    ),
    ?assertEqual(1, emqx_config:get_zone_conf(default, [mqtt, max_qos_allowed])),
    ?assertError(
        {config_not_found, [zones, no_default, mqtt, max_qos_allowed]},
        emqx_config:get_zone_conf(no_default, [mqtt, max_qos_allowed])
    ),
    %% Make sure the override config is updated, and remove the default value.
    ?assertMatch(#{<<"max_qos_allowed">> := 1}, read_conf(<<"mqtt">>)),

    BadZones = emqx_utils_maps:deep_put([<<"mqtt">>, <<"max_qos_allowed">>], Zones, 3),
    ?assertMatch({error, {"HTTP/1.1", 400, _}}, update_global_zone(BadZones)),

    %% Remove max_qos_allowed from raw config, but we still get default value(2).
    Mqtt0 = emqx_conf:get_raw([<<"mqtt">>]),
    ?assertEqual(1, emqx_utils_maps:deep_get([<<"max_qos_allowed">>], Mqtt0)),
    Mqtt1 = maps:remove(<<"max_qos_allowed">>, Mqtt0),
    ok = emqx_config:put_raw([<<"mqtt">>], Mqtt1),
    Mqtt2 = emqx_conf:get_raw([<<"mqtt">>]),
    ?assertNot(maps:is_key(<<"max_qos_allowed">>, Mqtt2), Mqtt2),
    {ok, #{<<"mqtt">> := Mqtt3}} = get_global_zone(),
    %% the default value is 2
    ?assertEqual(2, emqx_utils_maps:deep_get([<<"max_qos_allowed">>], Mqtt3)),
    ok = emqx_config:put_raw([<<"mqtt">>], Mqtt0),

    DefaultZones = emqx_utils_maps:deep_put([<<"mqtt">>, <<"max_qos_allowed">>], Zones, 2),
    {ok, #{}} = update_global_zone(DefaultZones),
    #{<<"mqtt">> := Mqtt} = emqx_config:fill_defaults(emqx_schema, #{<<"mqtt">> => #{}}, #{}),
    Default = maps:map(
        fun
            (_, V) when is_boolean(V) -> V;
            (_, V) when is_atom(V) -> atom_to_binary(V);
            (_, V) -> V
        end,
        Mqtt
    ),
    ?assertEqual(Default, read_conf(<<"mqtt">>)),
    ok.

get_global_zone() ->
    get_config("global_zone").

update_global_zone(Change) ->
    update_config("global_zone", Change).

%% hide /configs/zones api in 5.1.0, so we comment this test.
%t_zones(_Config) ->
%    {ok, Zones} = get_config("zones"),
%    {ok, #{<<"mqtt">> := OldMqtt} = Zone1} = get_global_zone(),
%    Mqtt1 = maps:remove(<<"max_subscriptions">>, OldMqtt),
%    {ok, #{}} = update_config("zones", Zones#{<<"new_zone">> => Zone1#{<<"mqtt">> => Mqtt1}}),
%     NewMqtt = emqx_config:get_raw([zones, new_zone, mqtt]),
%    %% we remove max_subscription from global zone, so the new zone should not have it.
%    ?assertEqual(Mqtt1, NewMqtt),
%    %% delete the new zones
%    {ok, #{}} = update_config("zones", Zones),
%    ?assertEqual(undefined, emqx_config:get_raw([zones, new_zone], undefined)),
%    ok.

t_dashboard(_Config) ->
    {ok, Dashboard = #{<<"listeners">> := Listeners}} = get_config("dashboard"),
    Https1 = #{enable => true, bind => 18084},
    ?assertMatch(
        {error, {"HTTP/1.1", 400, _}},
        update_config("dashboard", Dashboard#{<<"listeners">> => Listeners#{<<"https">> => Https1}})
    ),

    Https2 = #{
        <<"bind">> => 18084,
        <<"ssl_options">> =>
            #{
                <<"keyfile">> => "etc/certs/badkey.pem",
                <<"cacertfile">> => "etc/certs/badcacert.pem",
                <<"certfile">> => "etc/certs/badcert.pem"
            }
    },
    Dashboard2 = Dashboard#{<<"listeners">> => Listeners#{<<"https">> => Https2}},
    ?assertMatch(
        {error, {"HTTP/1.1", 400, _}},
        update_config("dashboard", Dashboard2)
    ),

    KeyFile = emqx_common_test_helpers:app_path(emqx, filename:join(["etc", "certs", "key.pem"])),
    CertFile = emqx_common_test_helpers:app_path(emqx, filename:join(["etc", "certs", "cert.pem"])),
    CacertFile = emqx_common_test_helpers:app_path(
        emqx, filename:join(["etc", "certs", "cacert.pem"])
    ),
    Https3 = #{
        <<"bind">> => 18084,
        <<"ssl_options">> => #{
            <<"keyfile">> => list_to_binary(KeyFile),
            <<"cacertfile">> => list_to_binary(CacertFile),
            <<"certfile">> => list_to_binary(CertFile)
        }
    },
    Dashboard3 = Dashboard#{<<"listeners">> => Listeners#{<<"https">> => Https3}},
    ?assertMatch({ok, _}, update_config("dashboard", Dashboard3)),

    Dashboard4 = Dashboard#{<<"listeners">> => Listeners#{<<"https">> => #{<<"bind">> => 0}}},
    ?assertMatch({ok, _}, update_config("dashboard", Dashboard4)),
    {ok, Dashboard41} = get_config("dashboard"),
    ?assertEqual(
        Https3#{<<"bind">> => 0},
        read_conf([<<"dashboard">>, <<"listeners">>, <<"https">>]),
        Dashboard41
    ),

    ?assertMatch({ok, _}, update_config("dashboard", Dashboard)),

    {ok, Dashboard1} = get_config("dashboard"),
    ?assertNotEqual(Dashboard, Dashboard1),
    timer:sleep(1500),
    ok.

%% v1 version json
t_configs_node({'init', Config}) ->
    Node = node(),
    meck:expect(emqx, running_nodes, fun() -> [Node, bad_node, other_node] end),
    F = fun
        (Node0) when Node0 =:= Node -> <<"\"self\"">>;
        (other_node) -> <<"\"other\"">>;
        (bad_node) -> {badrpc, bad}
    end,
    F2 = fun
        (Node0, _) when Node0 =:= Node -> <<"log=1">>;
        (other_node, _) -> <<"log=2">>;
        (bad_node, _) -> {badrpc, bad}
    end,
    meck:expect(emqx_management_proto_v4, get_full_config, F),
    meck:expect(emqx_conf_proto_v3, get_hocon_config, F2),
    meck:expect(hocon_pp, do, fun(Conf, _) -> Conf end),
    Config;
t_configs_node({'end', _}) ->
    meck:unload([emqx, emqx_management_proto_v4, emqx_conf_proto_v3, hocon_pp]);
t_configs_node(_) ->
    Node = atom_to_list(node()),

    ?assertEqual({ok, <<"self">>}, get_configs_with_json(Node, #{return_all => true})),
    ?assertEqual({ok, <<"other">>}, get_configs_with_json("other_node", #{return_all => true})),

    {ExpType, ExpRes} = get_configs_with_json("unknown_node", #{return_all => true}),
    ?assertEqual(error, ExpType),
    ?assertMatch({{_, 404, _}, _, _}, ExpRes),
    {_, _, Body} = ExpRes,
    ?assertMatch(#{<<"code">> := <<"NOT_FOUND">>}, emqx_utils_json:decode(Body, [return_maps])),

    ?assertMatch({error, {_, 500, _}}, get_configs_with_json("bad_node")),

    ?assertEqual({ok, #{<<"log">> => 1}}, get_configs_with_binary("log", Node)),
    ?assertEqual({ok, #{<<"log">> => 2}}, get_configs_with_binary("log", "other_node")).

%% v2 version binary
t_configs_key(_Config) ->
    Keys = lists:sort(emqx_conf_cli:keys()),
    {ok, Hocon} = get_configs_with_binary(undefined),
    ?assertEqual(Keys, lists:sort(maps:keys(Hocon))),
    {ok, Log} = get_configs_with_binary("log"),
    ?assertMatch(
        #{
            <<"log">> := #{
                <<"console">> := #{
                    <<"enable">> := _,
                    <<"formatter">> := <<"text">>,
                    <<"level">> := <<"warning">>,
                    <<"time_offset">> := <<"system">>
                },
                <<"file">> := _
            }
        },
        Log
    ),
    Log1 = emqx_utils_maps:deep_put([<<"log">>, <<"console">>, <<"level">>], Log, <<"error">>),
    ?assertEqual([], update_configs_with_binary(iolist_to_binary(hocon_pp:do(Log1, #{})))),
    ?assertEqual(<<"error">>, read_conf([<<"log">>, <<"console">>, <<"level">>])),
    ok.

t_get_configs_in_different_accept(_Config) ->
    [Key | _] = lists:sort(emqx_conf_cli:keys()),
    URI = emqx_mgmt_api_test_util:api_path(["configs?key=" ++ Key]),
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    Request = fun(Accept) ->
        Headers = [{"accept", Accept}, Auth],
        case
            emqx_mgmt_api_test_util:request_api(get, URI, [], Headers, [], #{return_all => true})
        of
            {ok, {{_, Code, _}, RespHeaders, Body}} ->
                Type = proplists:get_value("content-type", RespHeaders),
                {Code, Type, Body};
            {error, {{_, Code, _}, RespHeaders, Body}} ->
                Type = proplists:get_value("content-type", RespHeaders),
                {Code, Type, Body}
        end
    end,

    %% returns text/palin if text/plain is acceptable
    ?assertMatch({200, "text/plain", _}, Request(<<"text/plain">>)),
    ?assertMatch({200, "text/plain", _}, Request(<<"*/*">>)),
    ?assertMatch(
        {200, "text/plain", _},
        Request(<<"application/json, application/xml;q=0.9, image/webp, */*;q=0.8">>)
    ),
    %% returns application/json if it only support it
    ?assertMatch({200, "application/json", _}, Request(<<"application/json">>)),
    %% returns error if it set to other type
    ?assertMatch({400, "application/json", _}, Request(<<"application/xml">>)).

%% Helpers

get_config(Name) ->
    Path = emqx_mgmt_api_test_util:api_path(["configs", Name]),
    case emqx_mgmt_api_test_util:request_api(get, Path) of
        {ok, Res} ->
            {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error ->
            Error
    end.

get_configs_with_json() ->
    get_configs_with_json([], #{}).

get_configs_with_json(Node) ->
    get_configs_with_json(Node, #{}).

get_configs_with_json(Node, Opts) ->
    Path =
        case Node of
            [] -> ["configs"];
            _ -> ["configs?node=" ++ Node]
        end,
    URI = emqx_mgmt_api_test_util:api_path(Path),
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    Headers = [{"accept", "application/json"}, Auth],
    case emqx_mgmt_api_test_util:request_api(get, URI, [], Headers, [], Opts) of
        {ok, {_, _, Res}} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

get_configs_with_binary(Key) ->
    get_configs_with_binary(Key, atom_to_list(node())).

get_configs_with_binary(Key, Node) ->
    Path0 = "configs?node=" ++ Node,
    Path =
        case Key of
            undefined -> Path0;
            _ -> Path0 ++ "&key=" ++ Key
        end,
    URI = emqx_mgmt_api_test_util:api_path([Path]),
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    Headers = [{"accept", "text/plain"}, Auth],
    case emqx_mgmt_api_test_util:request_api(get, URI, [], Headers, [], #{return_all => true}) of
        {ok, {_, _, Res}} -> hocon:binary(Res);
        {ok, Res} -> hocon:binary(Res);
        Error -> Error
    end.

update_configs_with_binary(Bin) ->
    Path = emqx_mgmt_api_test_util:api_path(["configs"]),
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    Headers = [{"accept", "text/plain"}, Auth],
    case httpc:request(put, {Path, Headers, "text/plain", Bin}, [], []) of
        {ok, {_, _, Res}} -> Res;
        {ok, Res} -> Res;
        Error -> Error
    end.

update_config(Name, Change) ->
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    UpdatePath = emqx_mgmt_api_test_util:api_path(["configs", Name]),
    case emqx_mgmt_api_test_util:request_api(put, UpdatePath, "", AuthHeader, Change) of
        {ok, Update} -> {ok, emqx_utils_json:decode(Update, [return_maps])};
        Error -> Error
    end.

reset_config(Name, Key) ->
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Path = binary_to_list(
        iolist_to_binary(
            emqx_mgmt_api_test_util:api_path(["configs_reset", Name])
        )
    ),
    case emqx_mgmt_api_test_util:request_api(post, Path, Key, AuthHeader, []) of
        {ok, []} -> ok;
        Error -> Error
    end.

read_conf(RootKeys) when is_list(RootKeys) ->
    case emqx_config:read_override_conf(#{override_to => cluster}) of
        undefined -> undefined;
        Conf -> emqx_utils_maps:deep_get(RootKeys, Conf, undefined)
    end;
read_conf(RootKey) ->
    read_conf([RootKey]).
