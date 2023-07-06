%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_greptimedb_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    [
        {group, with_batch},
        {group, without_batch}
    ].

groups() ->
    TCs = emqx_common_test_helpers:all(?MODULE),
    [
        {with_batch, [
            {group, sync_query}
        ]},
        {without_batch, [
            {group, sync_query}
        ]},
        {sync_query, [
            {group, grpcv1_tcp},
            {group, grpcv1_tls}
        ]},
        {grpcv1_tcp, TCs},
        {grpcv1_tls, TCs}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    delete_all_bridges(),
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_connector_test_helpers:stop_apps([
        emqx_conf, emqx_bridge, emqx_resource, emqx_rule_engine
    ]),
    _ = application:stop(emqx_connector),
    ok.

init_per_group(GreptimedbType, Config0) when
    GreptimedbType =:= grpcv1_tcp;
    GreptimedbType =:= grpcv1_tls
->
    #{
        host := GreptimedbHost,
        port := GreptimedbPort,
        use_tls := UseTLS,
        proxy_name := ProxyName
    } =
        case GreptimedbType of
            grpcv1_tcp ->
                #{
                    host => os:getenv("GREPTIMEDB_GRPCV1_TCP_HOST", "toxiproxy"),
                    port => list_to_integer(os:getenv("GREPTIMEDB_GRPCV1_TCP_PORT", "4001")),
                    use_tls => false,
                    proxy_name => "greptimedb_tcp"
                };
            grpcv1_tls ->
                #{
                    host => os:getenv("GREPTIMEDB_GRPCV1_TLS_HOST", "toxiproxy"),
                    port => list_to_integer(os:getenv("GREPTIMEDB_GRPCV1_TLS_PORT", "4001")),
                    use_tls => true,
                    proxy_name => "greptimedb_tls"
                }
        end,
    case emqx_common_test_helpers:is_tcp_server_available(GreptimedbHost, GreptimedbPort) of
        true ->
            ProxyHost = os:getenv("PROXY_HOST", "toxiproxy"),
            ProxyPort = list_to_integer(os:getenv("PROXY_PORT", "8474")),
            emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
            ok = start_apps(),
            {ok, _} = application:ensure_all_started(emqx_connector),
            application:ensure_all_started(greptimedb),
            emqx_mgmt_api_test_util:init_suite(),
            Config = [{use_tls, UseTLS} | Config0],
            {Name, ConfigString, GreptimedbConfig} = greptimedb_config(
                grpcv1, GreptimedbHost, GreptimedbPort, Config
            ),
            EHttpcPoolNameBin = <<(atom_to_binary(?MODULE))/binary, "_grpcv1">>,
            EHttpcPoolName = binary_to_atom(EHttpcPoolNameBin),
            {EHttpcTransport, EHttpcTransportOpts} =
                case UseTLS of
                    true -> {tls, [{verify, verify_none}]};
                    false -> {tcp, []}
                end,
            EHttpcPoolOpts = [
                {host, GreptimedbHost},
                {port, GreptimedbPort},
                {pool_size, 1},
                {transport, EHttpcTransport},
                {transport_opts, EHttpcTransportOpts}
            ],
            {ok, _} = ehttpc_sup:start_pool(EHttpcPoolName, EHttpcPoolOpts),
            [
                {proxy_host, ProxyHost},
                {proxy_port, ProxyPort},
                {proxy_name, ProxyName},
                {greptimedb_host, GreptimedbHost},
                {greptimedb_port, GreptimedbPort},
                {greptimedb_type, grpcv1},
                {greptimedb_config, GreptimedbConfig},
                {greptimedb_config_string, ConfigString},
                {ehttpc_pool_name, EHttpcPoolName},
                {greptimedb_name, Name}
                | Config
            ];
        false ->
            {skip, no_greptimedb}
    end;
init_per_group(sync_query, Config) ->
    [{query_mode, sync} | Config];
init_per_group(with_batch, Config) ->
    [{batch_size, 100} | Config];
init_per_group(without_batch, Config) ->
    [{batch_size, 1} | Config];
init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, Config) when
    Group =:= grpcv1_tcp;
    Group =:= grpcv1_tls
->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    EHttpcPoolName = ?config(ehttpc_pool_name, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    ehttpc_sup:stop_pool(EHttpcPoolName),
    delete_bridge(Config),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Testcase, Config) ->
    delete_all_rules(),
    delete_all_bridges(),
    Config.

end_per_testcase(_Testcase, Config) ->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    ok = snabbkaffe:stop(),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    delete_all_rules(),
    delete_all_bridges(),
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

start_apps() ->
    %% some configs in emqx_conf app are mandatory
    %% we want to make sure they are loaded before
    %% ekka start in emqx_common_test_helpers:start_apps/1
    emqx_common_test_helpers:render_and_load_app_config(emqx_conf),
    ok = emqx_common_test_helpers:start_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:start_apps([emqx_resource, emqx_bridge, emqx_rule_engine]).

example_write_syntax() ->
    %% N.B.: this single space character is relevant
    <<"${topic},clientid=${clientid}", " ", "payload=${payload},",
        "${clientid}_int_value=${payload.int_key}i,",
        "uint_value=${payload.uint_key}u,"
        "float_value=${payload.float_key},", "undef_value=${payload.undef},",
        "${undef_key}=\"hard-coded-value\",", "bool=${payload.bool}">>.

greptimedb_config(grpcv1 = Type, GreptimedbHost, GreptimedbPort, Config) ->
    BatchSize = proplists:get_value(batch_size, Config, 100),
    QueryMode = proplists:get_value(query_mode, Config, sync),
    UseTLS = proplists:get_value(use_tls, Config, false),
    Name = atom_to_binary(?MODULE),
    WriteSyntax = example_write_syntax(),
    ConfigString =
        io_lib:format(
            "bridges.greptimedb_grpc_v1.~s {\n"
            "  enable = true\n"
            "  server = \"~p:~b\"\n"
            "  dbname = public\n"
            "  username = greptime_user\n"
            "  password = greptime_pwd\n"
            "  precision = ns\n"
            "  write_syntax = \"~s\"\n"
            "  resource_opts = {\n"
            "    request_ttl = 1s\n"
            "    query_mode = ~s\n"
            "    batch_size = ~b\n"
            "  }\n"
            "  ssl {\n"
            "    enable = ~p\n"
            "    verify = verify_none\n"
            "  }\n"
            "}\n",
            [
                Name,
                GreptimedbHost,
                GreptimedbPort,
                WriteSyntax,
                QueryMode,
                BatchSize,
                UseTLS
            ]
        ),
    {Name, ConfigString, parse_and_check(ConfigString, Type, Name)}.

parse_and_check(ConfigString, Type, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    TypeBin = greptimedb_type_bin(Type),
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{TypeBin := #{Name := Config}}} = RawConf,
    Config.

greptimedb_type_bin(grpcv1) ->
    <<"greptimedb_grpc_v1">>.

create_bridge(Config) ->
    create_bridge(Config, _Overrides = #{}).

create_bridge(Config, Overrides) ->
    Type = greptimedb_type_bin(?config(greptimedb_type, Config)),
    Name = ?config(greptimedb_name, Config),
    GreptimedbConfig0 = ?config(greptimedb_config, Config),
    GreptimedbConfig = emqx_utils_maps:deep_merge(GreptimedbConfig0, Overrides),
    emqx_bridge:create(Type, Name, GreptimedbConfig).

delete_bridge(Config) ->
    Type = greptimedb_type_bin(?config(greptimedb_type, Config)),
    Name = ?config(greptimedb_name, Config),
    emqx_bridge:remove(Type, Name).

delete_all_bridges() ->
    lists:foreach(
        fun(#{name := Name, type := Type}) ->
            emqx_bridge:remove(Type, Name)
        end,
        emqx_bridge:list()
    ).

delete_all_rules() ->
    lists:foreach(
        fun(#{id := RuleId}) ->
            ok = emqx_rule_engine:delete_rule(RuleId)
        end,
        emqx_rule_engine:get_rules()
    ).

create_rule_and_action_http(Config) ->
    create_rule_and_action_http(Config, _Overrides = #{}).

create_rule_and_action_http(Config, Overrides) ->
    GreptimedbName = ?config(greptimedb_name, Config),
    Type = greptimedb_type_bin(?config(greptimedb_type, Config)),
    BridgeId = emqx_bridge_resource:bridge_id(Type, GreptimedbName),
    Params0 = #{
        enable => true,
        sql => <<"SELECT * FROM \"t/topic\"">>,
        actions => [BridgeId]
    },
    Params = emqx_utils_maps:deep_merge(Params0, Overrides),
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

send_message(Config, Payload) ->
    Name = ?config(greptimedb_name, Config),
    Type = greptimedb_type_bin(?config(greptimedb_type, Config)),
    BridgeId = emqx_bridge_resource:bridge_id(Type, Name),
    emqx_bridge:send_message(BridgeId, Payload).

query_by_clientid(ClientId, Config) ->
    GreptimedbHost = ?config(greptimedb_host, Config),
    GreptimedbPort = ?config(greptimedb_port, Config),
    EHttpcPoolName = ?config(ehttpc_pool_name, Config),
    UseTLS = ?config(use_tls, Config),
    Path = <<"/api/v2/query?org=emqx">>,
    Scheme =
        case UseTLS of
            true -> <<"https://">>;
            false -> <<"http://">>
        end,
    URI = iolist_to_binary([
        Scheme,
        list_to_binary(GreptimedbHost),
        ":",
        integer_to_binary(GreptimedbPort),
        Path
    ]),
    Query =
        <<
            "from(bucket: \"mqtt\")\n"
            "  |> range(start: -12h)\n"
            "  |> filter(fn: (r) => r.clientid == \"",
            ClientId/binary,
            "\")"
        >>,
    Headers = [
        {"Authorization", "Token abcdefg"},
        {"Content-Type", "application/json"}
    ],
    Body =
        emqx_utils_json:encode(#{
            query => Query,
            dialect => #{
                header => true,
                delimiter => <<";">>
            }
        }),
    {ok, 200, _Headers, RawBody0} =
        ehttpc:request(
            EHttpcPoolName,
            post,
            {URI, Headers, Body},
            _Timeout = 10_000,
            _Retry = 0
        ),
    RawBody1 = iolist_to_binary(string:replace(RawBody0, <<"\r\n">>, <<"\n">>, all)),
    {ok, DecodedCSV0} = erl_csv:decode(RawBody1, #{separator => <<$;>>}),
    DecodedCSV1 = [
        [Field || Field <- Line, Field =/= <<>>]
     || Line <- DecodedCSV0,
        Line =/= [<<>>]
    ],
    DecodedCSV2 = csv_lines_to_maps(DecodedCSV1, []),
    index_by_field(DecodedCSV2).

decode_csv(RawBody) ->
    Lines =
        [
            binary:split(Line, [<<";">>], [global, trim_all])
         || Line <- binary:split(RawBody, [<<"\r\n">>], [global, trim_all])
        ],
    csv_lines_to_maps(Lines, []).

csv_lines_to_maps([Fields, Data | Rest], Acc) ->
    Map = maps:from_list(lists:zip(Fields, Data)),
    csv_lines_to_maps(Rest, [Map | Acc]);
csv_lines_to_maps(_Data, Acc) ->
    lists:reverse(Acc).

index_by_field(DecodedCSV) ->
    maps:from_list([{Field, Data} || Data = #{<<"_field">> := Field} <- DecodedCSV]).

assert_persisted_data(ClientId, Expected, PersistedData) ->
    ClientIdIntKey = <<ClientId/binary, "_int_value">>,
    maps:foreach(
        fun
            (int_value, ExpectedValue) ->
                ?assertMatch(
                    #{<<"_value">> := ExpectedValue},
                    maps:get(ClientIdIntKey, PersistedData)
                );
            (Key, ExpectedValue) ->
                ?assertMatch(
                    #{<<"_value">> := ExpectedValue},
                    maps:get(atom_to_binary(Key), PersistedData),
                    #{expected => ExpectedValue}
                )
        end,
        Expected
    ),
    ok.

resource_id(Config) ->
    Type = greptimedb_type_bin(?config(greptimedb_type, Config)),
    Name = ?config(greptimedb_name, Config),
    emqx_bridge_resource:resource_id(Type, Name).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_start_ok(Config) ->
    QueryMode = ?config(query_mode, Config),
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    Payload = #{
        int_key => -123,
        bool => true,
        float_key => 24.5,
        uint_key => 123
    },
    SentData = #{
        <<"clientid">> => ClientId,
        <<"topic">> => atom_to_binary(?FUNCTION_NAME),
        <<"payload">> => Payload,
        <<"timestamp">> => erlang:system_time(millisecond)
    },
    ?check_trace(
        begin
            case QueryMode of
                sync ->
                    ?assertMatch(ok, send_message(Config, SentData))
            end,
            PersistedData = query_by_clientid(ClientId, Config),
            Expected = #{
                bool => <<"true">>,
                int_value => <<"-123">>,
                uint_value => <<"123">>,
                float_value => <<"24.5">>,
                payload => emqx_utils_json:encode(Payload)
            },
            assert_persisted_data(ClientId, Expected, PersistedData),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(greptimedb_connector_send_query, Trace0),
            ?assertMatch([#{points := [_]}], Trace),
            [#{points := [Point]}] = Trace,
            ct:pal("sent point: ~p", [Point]),
            ?assertMatch(
                #{
                    fields := #{},
                    measurement := <<_/binary>>,
                    tags := #{},
                    timestamp := TS
                } when is_integer(TS),
                Point
            ),
            #{fields := Fields} = Point,
            ?assert(lists:all(fun is_binary/1, maps:keys(Fields))),
            ?assertNot(maps:is_key(<<"undefined">>, Fields)),
            ?assertNot(maps:is_key(<<"undef_value">>, Fields)),
            ok
        end
    ),
    ok.

t_start_already_started(Config) ->
    Type = greptimedb_type_bin(?config(greptimedb_type, Config)),
    Name = ?config(greptimedb_name, Config),
    GreptimedbConfigString = ?config(greptimedb_config_string, Config),
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    ResourceId = resource_id(Config),
    TypeAtom = binary_to_atom(Type),
    NameAtom = binary_to_atom(Name),
    {ok, #{bridges := #{TypeAtom := #{NameAtom := GreptimedbConfigMap}}}} = emqx_hocon:check(
        emqx_bridge_schema, GreptimedbConfigString
    ),
    ?check_trace(
        emqx_bridge_greptimedb_connector:on_start(ResourceId, GreptimedbConfigMap),
        fun(Result, Trace) ->
            ?assertMatch({ok, _}, Result),
            ?assertMatch([_], ?of_kind(greptimedb_connector_start_already_started, Trace)),
            ok
        end
    ),
    ok.

t_start_ok_timestamp_write_syntax(Config) ->
    GreptimedbType = ?config(greptimedb_type, Config),
    GreptimedbName = ?config(greptimedb_name, Config),
    GreptimedbConfigString0 = ?config(greptimedb_config_string, Config),
    GreptimedbTypeCfg =
        case GreptimedbType of
            grpcv1 -> "greptimedb_grpc_v1"
        end,
    WriteSyntax =
        %% N.B.: this single space characters are relevant
        <<"${topic},clientid=${clientid}", " ", "payload=${payload},",
            "${clientid}_int_value=${payload.int_key}i,",
            "uint_value=${payload.uint_key}u,"
            "bool=${payload.bool}", " ", "${timestamp}">>,
    %% append this to override the config
    GreptimedbConfigString1 =
        io_lib:format(
            "bridges.~s.~s {\n"
            "  write_syntax = \"~s\"\n"
            "}\n",
            [GreptimedbTypeCfg, GreptimedbName, WriteSyntax]
        ),
    GreptimedbConfig1 = parse_and_check(
        GreptimedbConfigString0 ++ GreptimedbConfigString1,
        GreptimedbType,
        GreptimedbName
    ),
    Config1 = [{greptimedb_config, GreptimedbConfig1} | Config],
    ?assertMatch(
        {ok, _},
        create_bridge(Config1)
    ),
    ok.

t_start_ok_no_subject_tags_write_syntax(Config) ->
    GreptimedbType = ?config(greptimedb_type, Config),
    GreptimedbName = ?config(greptimedb_name, Config),
    GreptimedbConfigString0 = ?config(greptimedb_config_string, Config),
    GreptimedbTypeCfg =
        case GreptimedbType of
            grpcv1 -> "greptimedb_grpc_v1"
        end,
    WriteSyntax =
        %% N.B.: this single space characters are relevant
        <<"${topic}", " ", "payload=${payload},", "${clientid}_int_value=${payload.int_key}i,",
            "uint_value=${payload.uint_key}u,"
            "bool=${payload.bool}", " ", "${timestamp}">>,
    %% append this to override the config
    GreptimedbConfigString1 =
        io_lib:format(
            "bridges.~s.~s {\n"
            "  write_syntax = \"~s\"\n"
            "}\n",
            [GreptimedbTypeCfg, GreptimedbName, WriteSyntax]
        ),
    GreptimedbConfig1 = parse_and_check(
        GreptimedbConfigString0 ++ GreptimedbConfigString1,
        GreptimedbType,
        GreptimedbName
    ),
    Config1 = [{greptimedb_config, GreptimedbConfig1} | Config],
    ?assertMatch(
        {ok, _},
        create_bridge(Config1)
    ),
    ok.

t_const_timestamp(Config) ->
    QueryMode = ?config(query_mode, Config),
    Const = erlang:system_time(nanosecond),
    ConstBin = integer_to_binary(Const),
    TsStr = iolist_to_binary(
        calendar:system_time_to_rfc3339(Const, [{unit, nanosecond}, {offset, "Z"}])
    ),
    ?assertMatch(
        {ok, _},
        create_bridge(
            Config,
            #{
                <<"write_syntax">> =>
                    <<"mqtt,clientid=${clientid} foo=${payload.foo}i,bar=5i ", ConstBin/binary>>
            }
        )
    ),
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    Payload = #{<<"foo">> => 123},
    SentData = #{
        <<"clientid">> => ClientId,
        <<"topic">> => atom_to_binary(?FUNCTION_NAME),
        <<"payload">> => Payload,
        <<"timestamp">> => erlang:system_time(millisecond)
    },
    case QueryMode of
        sync ->
            ?assertMatch(ok, send_message(Config, SentData))
    end,
    PersistedData = query_by_clientid(ClientId, Config),
    Expected = #{foo => <<"123">>},
    assert_persisted_data(ClientId, Expected, PersistedData),
    TimeReturned0 = maps:get(<<"_time">>, maps:get(<<"foo">>, PersistedData)),
    TimeReturned = pad_zero(TimeReturned0),
    ?assertEqual(TsStr, TimeReturned).

%% greptimedb returns timestamps without trailing zeros such as
%% "2023-02-28T17:21:51.63678163Z"
%% while the standard should be
%% "2023-02-28T17:21:51.636781630Z"
pad_zero(BinTs) ->
    StrTs = binary_to_list(BinTs),
    [Nano | Rest] = lists:reverse(string:tokens(StrTs, ".")),
    [$Z | NanoNum] = lists:reverse(Nano),
    Padding = lists:duplicate(10 - length(Nano), $0),
    NewNano = lists:reverse(NanoNum) ++ Padding ++ "Z",
    iolist_to_binary(string:join(lists:reverse([NewNano | Rest]), ".")).

t_boolean_variants(Config) ->
    QueryMode = ?config(query_mode, Config),
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    BoolVariants = #{
        true => true,
        false => false,
        <<"t">> => true,
        <<"f">> => false,
        <<"T">> => true,
        <<"F">> => false,
        <<"TRUE">> => true,
        <<"FALSE">> => false,
        <<"True">> => true,
        <<"False">> => false
    },
    maps:foreach(
        fun(BoolVariant, Translation) ->
            ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
            Payload = #{
                int_key => -123,
                bool => BoolVariant,
                uint_key => 123
            },
            SentData = #{
                <<"clientid">> => ClientId,
                <<"topic">> => atom_to_binary(?FUNCTION_NAME),
                <<"timestamp">> => erlang:system_time(millisecond),
                <<"payload">> => Payload
            },
            case QueryMode of
                sync ->
                    ?assertMatch(ok, send_message(Config, SentData))
            end,
            case QueryMode of
                sync -> ok
            end,
            PersistedData = query_by_clientid(ClientId, Config),
            Expected = #{
                bool => atom_to_binary(Translation),
                int_value => <<"-123">>,
                uint_value => <<"123">>,
                payload => emqx_utils_json:encode(Payload)
            },
            assert_persisted_data(ClientId, Expected, PersistedData),
            ok
        end,
        BoolVariants
    ),
    ok.

t_bad_timestamp(Config) ->
    GreptimedbType = ?config(greptimedb_type, Config),
    GreptimedbName = ?config(greptimedb_name, Config),
    QueryMode = ?config(query_mode, Config),
    BatchSize = ?config(batch_size, Config),
    GreptimedbConfigString0 = ?config(greptimedb_config_string, Config),
    GreptimedbTypeCfg =
        case GreptimedbType of
            grpcv1 -> "greptimedb_grpc_v1"
        end,
    WriteSyntax =
        %% N.B.: this single space characters are relevant
        <<"${topic}", " ", "payload=${payload},", "${clientid}_int_value=${payload.int_key}i,",
            "uint_value=${payload.uint_key}u,"
            "bool=${payload.bool}", " ", "bad_timestamp">>,
    %% append this to override the config
    GreptimedbConfigString1 =
        io_lib:format(
            "bridges.~s.~s {\n"
            "  write_syntax = \"~s\"\n"
            "}\n",
            [GreptimedbTypeCfg, GreptimedbName, WriteSyntax]
        ),
    GreptimedbConfig1 = parse_and_check(
        GreptimedbConfigString0 ++ GreptimedbConfigString1,
        GreptimedbType,
        GreptimedbName
    ),
    Config1 = [{greptimedb_config, GreptimedbConfig1} | Config],
    ?assertMatch(
        {ok, _},
        create_bridge(Config1)
    ),
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    Payload = #{
        int_key => -123,
        bool => false,
        uint_key => 123
    },
    SentData = #{
        <<"clientid">> => ClientId,
        <<"topic">> => atom_to_binary(?FUNCTION_NAME),
        <<"timestamp">> => erlang:system_time(millisecond),
        <<"payload">> => Payload
    },
    ?check_trace(
        ?wait_async_action(
            send_message(Config1, SentData),
            #{?snk_kind := greptimedb_connector_send_query_error},
            10_000
        ),
        fun(Result, _Trace) ->
            ?assertMatch({_, {ok, _}}, Result),
            {Return, {ok, _}} = Result,
            IsBatch = BatchSize > 1,
            case {QueryMode, IsBatch} of
                {sync, false} ->
                    ?assertEqual(
                        {error, [
                            {error, {bad_timestamp, <<"bad_timestamp">>}}
                        ]},
                        Return
                    );
                {sync, true} ->
                    ?assertEqual({error, {unrecoverable_error, points_trans_failed}}, Return)
            end,
            ok
        end
    ),
    ok.

t_get_status(Config) ->
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),
    {ok, _} = create_bridge(Config),
    ResourceId = resource_id(Config),
    ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId)),
    emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
        ?assertEqual({ok, disconnected}, emqx_resource_manager:health_check(ResourceId))
    end),
    ok.

t_create_disconnected(Config) ->
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),
    ?check_trace(
        emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
            ?assertMatch({ok, _}, create_bridge(Config))
        end),
        fun(Trace) ->
            ?assertMatch(
                [#{error := greptimedb_client_not_alive, reason := econnrefused}],
                ?of_kind(greptimedb_connector_start_failed, Trace)
            ),
            ok
        end
    ),
    ok.

t_start_error(Config) ->
    %% simulate client start error
    ?check_trace(
        emqx_common_test_helpers:with_mock(
            greptimedb,
            start_client,
            fun(_Config) -> {error, some_error} end,
            fun() ->
                ?wait_async_action(
                    ?assertMatch({ok, _}, create_bridge(Config)),
                    #{?snk_kind := greptimedb_connector_start_failed},
                    10_000
                )
            end
        ),
        fun(Trace) ->
            ?assertMatch(
                [#{error := some_error}],
                ?of_kind(greptimedb_connector_start_failed, Trace)
            ),
            ok
        end
    ),
    ok.

t_start_exception(Config) ->
    %% simulate client start exception
    ?check_trace(
        emqx_common_test_helpers:with_mock(
            greptimedb,
            start_client,
            fun(_Config) -> error(boom) end,
            fun() ->
                ?wait_async_action(
                    ?assertMatch({ok, _}, create_bridge(Config)),
                    #{?snk_kind := greptimedb_connector_start_exception},
                    10_000
                )
            end
        ),
        fun(Trace) ->
            ?assertMatch(
                [#{error := {error, boom}}],
                ?of_kind(greptimedb_connector_start_exception, Trace)
            ),
            ok
        end
    ),
    ok.

t_write_failure(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    QueryMode = ?config(query_mode, Config),
    {ok, _} = create_bridge(Config),
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    Payload = #{
        int_key => -123,
        bool => true,
        float_key => 24.5,
        uint_key => 123
    },
    SentData = #{
        <<"clientid">> => ClientId,
        <<"topic">> => atom_to_binary(?FUNCTION_NAME),
        <<"timestamp">> => erlang:system_time(millisecond),
        <<"payload">> => Payload
    },
    ?check_trace(
        emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
            case QueryMode of
                sync ->
                    {_, {ok, _}} =
                        ?wait_async_action(
                            ?assertMatch(
                                {error, {resource_error, #{reason := timeout}}},
                                send_message(Config, SentData)
                            ),
                            #{?snk_kind := handle_async_reply, action := nack},
                            1_000
                        )
            end
        end),
        fun(Trace0) ->
            case QueryMode of
                sync ->
                    Trace = ?of_kind(handle_async_reply, Trace0),
                    ?assertMatch([_ | _], Trace),
                    [#{result := Result} | _] = Trace,
                    ?assert(
                        not emqx_bridge_greptimedb_connector:is_unrecoverable_error(Result),
                        #{got => Result}
                    )
            end,
            ok
        end
    ),
    ok.

t_missing_field(Config) ->
    BatchSize = ?config(batch_size, Config),
    IsBatch = BatchSize > 1,
    {ok, _} =
        create_bridge(
            Config,
            #{
                <<"resource_opts">> => #{<<"worker_pool_size">> => 1},
                <<"write_syntax">> => <<"${clientid} foo=${foo}i">>
            }
        ),
    %% note: we don't select foo here, but we interpolate it in the
    %% fields, so it'll become undefined.
    {ok, _} = create_rule_and_action_http(Config, #{sql => <<"select * from \"t/topic\"">>}),
    ClientId0 = emqx_guid:to_hexstr(emqx_guid:gen()),
    ClientId1 = emqx_guid:to_hexstr(emqx_guid:gen()),
    %% Message with the field that we "forgot" to select in the rule
    Msg0 = emqx_message:make(ClientId0, <<"t/topic">>, emqx_utils_json:encode(#{foo => 123})),
    %% Message without any fields
    Msg1 = emqx_message:make(ClientId1, <<"t/topic">>, emqx_utils_json:encode(#{})),
    ?check_trace(
        begin
            emqx:publish(Msg0),
            emqx:publish(Msg1),
            NEvents = 1,
            {ok, _} =
                snabbkaffe:block_until(
                    ?match_n_events(NEvents, #{
                        ?snk_kind := greptimedb_connector_send_query_error
                    }),
                    _Timeout1 = 10_000
                ),
            ok
        end,
        fun(Trace) ->
            PersistedData0 = query_by_clientid(ClientId0, Config),
            PersistedData1 = query_by_clientid(ClientId1, Config),
            case IsBatch of
                true ->
                    ?assertMatch(
                        [#{error := points_trans_failed} | _],
                        ?of_kind(greptimedb_connector_send_query_error, Trace)
                    );
                false ->
                    ?assertMatch(
                        [#{error := [{error, no_fields}]} | _],
                        ?of_kind(greptimedb_connector_send_query_error, Trace)
                    )
            end,
            %% nothing should have been persisted
            ?assertEqual(#{}, PersistedData0),
            ?assertEqual(#{}, PersistedData1),
            ok
        end
    ),
    ok.

t_authentication_error(Config0) ->
    GreptimedbType = ?config(greptimedb_type, Config0),
    GreptimeConfig0 = proplists:get_value(greptimedb_config, Config0),
    GreptimeConfig =
        case GreptimedbType of
            grpcv1 -> GreptimeConfig0#{<<"password">> => <<"wrong_password">>}
        end,
    Config = lists:keyreplace(greptimedb_config, 1, Config0, {greptimedb_config, GreptimeConfig}),
    ?check_trace(
        begin
            ?wait_async_action(
                create_bridge(Config),
                #{?snk_kind := greptimedb_connector_start_failed},
                10_000
            )
        end,
        fun(Trace) ->
            ?assertMatch(
                [#{error := auth_error} | _],
                ?of_kind(greptimedb_connector_start_failed, Trace)
            ),
            ok
        end
    ),
    ok.

t_authentication_error_on_get_status(Config0) ->
    ResourceId = resource_id(Config0),

    % Fake initialization to simulate credential update after bridge was created.
    emqx_common_test_helpers:with_mock(
        greptimedb,
        check_auth,
        fun(_) ->
            ok
        end,
        fun() ->
            GreptimedbType = ?config(greptimedb_type, Config0),
            GreptimeConfig0 = proplists:get_value(greptimedb_config, Config0),
            GreptimeConfig =
                case GreptimedbType of
                    grpcv1 -> GreptimeConfig0#{<<"password">> => <<"wrong_password">>}
                end,
            Config = lists:keyreplace(
                greptimedb_config, 1, Config0, {greptimedb_config, GreptimeConfig}
            ),
            {ok, _} = create_bridge(Config),
            ?retry(
                _Sleep = 1_000,
                _Attempts = 10,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            )
        end
    ),

    % Now back to wrong credentials
    ?assertEqual({ok, disconnected}, emqx_resource_manager:health_check(ResourceId)),
    ok.

t_authentication_error_on_send_message(Config0) ->
    ResourceId = resource_id(Config0),
    QueryMode = proplists:get_value(query_mode, Config0, sync),
    GreptimedbType = ?config(greptimedb_type, Config0),
    GreptimeConfig0 = proplists:get_value(greptimedb_config, Config0),
    GreptimeConfig =
        case GreptimedbType of
            grpcv1 -> GreptimeConfig0#{<<"password">> => <<"wrong_password">>}
        end,
    Config = lists:keyreplace(greptimedb_config, 1, Config0, {greptimedb_config, GreptimeConfig}),

    % Fake initialization to simulate credential update after bridge was created.
    emqx_common_test_helpers:with_mock(
        greptimedb,
        check_auth,
        fun(_) ->
            ok
        end,
        fun() ->
            {ok, _} = create_bridge(Config),
            ?retry(
                _Sleep = 1_000,
                _Attempts = 10,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            )
        end
    ),

    % Now back to wrong credentials
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    Payload = #{
        int_key => -123,
        bool => true,
        float_key => 24.5,
        uint_key => 123
    },
    SentData = #{
        <<"clientid">> => ClientId,
        <<"topic">> => atom_to_binary(?FUNCTION_NAME),
        <<"timestamp">> => erlang:system_time(millisecond),
        <<"payload">> => Payload
    },
    case QueryMode of
        sync ->
            ?assertMatch(
                {error, {unrecoverable_error, <<"authorization failure">>}},
                send_message(Config, SentData)
            )
    end,
    ok.
