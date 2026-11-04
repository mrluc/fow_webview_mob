-module(mob_webview_nif).
-export([install/0]).
-on_load(init/0).
init() ->
    case erlang:load_nif("mob_webview_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.
install() -> erlang:nif_error(nif_not_loaded).
