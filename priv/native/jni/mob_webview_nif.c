#include <erl_nif.h>
#ifdef __APPLE__
extern void mob_webview_register(void);
#endif
static ERL_NIF_TERM install(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
#ifdef __APPLE__
    mob_webview_register();
#endif
    return enif_make_atom(env, "ok");
}
static ErlNifFunc funcs[] = {{"install", 0, install}};
ERL_NIF_INIT(mob_webview_nif, funcs, NULL, NULL, NULL, NULL)
