%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_greptimedb_connector_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_connector/include/emqx_connector.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(GREPTIMEDB_RESOURCE_MOD, emqx_bridge_greptimedb_connector).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_suite(Config) ->
    GreptimedbTCPHost = os:getenv("GREPTIMEDB_GRPCV1_TCP_HOST", "toxiproxy"),
    GreptimedbTCPPort = list_to_integer(os:getenv("GREPTIMEDB_GRPCV1_TCP_PORT", "4001")),
    Servers = [{GreptimedbTCPHost, GreptimedbTCPPort}],
    case emqx_common_test_helpers:is_all_tcp_servers_available(Servers) of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_conf]),
            ok = emqx_connector_test_helpers:start_apps([emqx_resource]),
            {ok, _} = application:ensure_all_started(emqx_connector),
            {ok, _} = application:ensure_all_started(greptimedb),
            [
                {greptimedb_tcp_host, GreptimedbTCPHost},
                {greptimedb_tcp_port, GreptimedbTCPPort}
                | Config
            ];
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_greptimedb);
                _ ->
                    {skip, no_greptimedb}
            end
    end.

end_per_suite(_Config) ->
    ok = emqx_common_test_helpers:stop_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:stop_apps([emqx_resource]),
    _ = application:stop(emqx_connector),
    _ = application:stop(greptimedb),
    ok.

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    ok.

% %%------------------------------------------------------------------------------
% %% Testcases
% %%------------------------------------------------------------------------------

t_lifecycle(Config) ->
    Host = ?config(greptimedb_tcp_host, Config),
    Port = ?config(greptimedb_tcp_port, Config),
    perform_lifecycle_check(
        <<"emqx_bridge_greptimedb_connector_SUITE">>,
        greptimedb_config(Host, Port)
    ).

perform_lifecycle_check(PoolName, InitialConfig) ->
    {ok, #{config := CheckedConfig}} =
        emqx_resource:check_config(?GREPTIMEDB_RESOURCE_MOD, InitialConfig),
    % We need to add a write_syntax to the config since the connector
    % expects this
    FullConfig = CheckedConfig#{write_syntax => greptimedb_write_syntax()},
    {ok, #{
        state := #{client := #{pool := ReturnedPoolName}} = State,
        status := InitialStatus
    }} = emqx_resource:create_local(
        PoolName,
        ?CONNECTOR_RESOURCE_GROUP,
        ?GREPTIMEDB_RESOURCE_MOD,
        FullConfig,
        #{}
    ),
    ?assertEqual(InitialStatus, connected),
    % Instance should match the state and status of the just started resource
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := InitialStatus
    }} =
        emqx_resource:get_instance(PoolName),
    ?assertEqual({ok, connected}, emqx_resource:health_check(PoolName)),
    % % Perform query as further check that the resource is working as expected
    ?assertMatch({ok, _}, emqx_resource:query(PoolName, test_query())),
    ?assertEqual(ok, emqx_resource:stop(PoolName)),
    % Resource will be listed still, but state will be changed and healthcheck will fail
    % as the worker no longer exists.
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := StoppedStatus
    }} =
        emqx_resource:get_instance(PoolName),
    ?assertEqual(stopped, StoppedStatus),
    ?assertEqual({error, resource_is_stopped}, emqx_resource:health_check(PoolName)),
    % Resource healthcheck shortcuts things by checking ets. Go deeper by checking pool itself.
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(ReturnedPoolName)),
    % Can call stop/1 again on an already stopped instance
    ?assertEqual(ok, emqx_resource:stop(PoolName)),
    % Make sure it can be restarted and the healthchecks and queries work properly
    ?assertEqual(ok, emqx_resource:restart(PoolName)),
    % async restart, need to wait resource
    timer:sleep(500),
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{status := InitialStatus}} =
        emqx_resource:get_instance(PoolName),
    ?assertEqual({ok, connected}, emqx_resource:health_check(PoolName)),
    ?assertMatch({ok, _}, emqx_resource:query(PoolName, test_query())),
    % Stop and remove the resource in one go.
    ?assertEqual(ok, emqx_resource:remove_local(PoolName)),
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(ReturnedPoolName)),
    % Should not even be able to get the resource data out of ets now unlike just stopping.
    ?assertEqual({error, not_found}, emqx_resource:get_instance(PoolName)).

% %%------------------------------------------------------------------------------
% %% Helpers
% %%------------------------------------------------------------------------------

greptimedb_config(Host, Port) ->
    Server = list_to_binary(io_lib:format("~s:~b", [Host, Port])),
    ResourceConfig = #{
        <<"dbname">> => <<"public">>,
        <<"server">> => Server,
        <<"username">> => <<"greptime_user">>,
        <<"password">> => <<"greptime_pwd">>
    },
    #{<<"config">> => ResourceConfig}.

greptimedb_write_syntax() ->
    [
        #{
            measurement => "${topic}",
            tags => [{"clientid", "${clientid}"}],
            fields => [{"payload", "${payload}"}],
            timestamp => undefined
        }
    ].

test_query() ->
    {send_message, #{
        <<"clientid">> => <<"something">>,
        <<"payload">> => #{bool => true},
        <<"topic">> => <<"connector_test">>,
        <<"timestamp">> => 1678220316257
    }}.
