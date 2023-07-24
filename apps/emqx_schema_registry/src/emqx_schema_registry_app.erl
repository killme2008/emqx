%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_schema_registry_app).

-behaviour(application).

-include("emqx_schema_registry.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Register rule engine extra functions module so that we can handle decode
    %% and encode functions called from the rule engine SQL like language
    ok = emqx_rule_engine:set_extra_functions_module(emqx_schema_registry_serde),
    ok = mria_rlog:wait_for_shards([?SCHEMA_REGISTRY_SHARD], infinity),
    %% HTTP API handler
    emqx_conf:add_handler([?CONF_KEY_ROOT, schemas, '?'], emqx_schema_registry),
    %% Conf load / data import handler
    emqx_conf:add_handler(?CONF_KEY_PATH, emqx_schema_registry),
    emqx_schema_registry_sup:start_link().

stop(_State) ->
    emqx_conf:remove_handler([?CONF_KEY_ROOT, schemas, '?']),
    emqx_conf:remove_handler(?CONF_KEY_PATH),
    ok.
