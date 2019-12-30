#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <Python.h>
#include "nginx.h"
#include "ngx_python_module.h"


static ngx_int_t ngx_python_init_process(ngx_cycle_t *cycle);
static void ngx_python_exit_process(ngx_cycle_t *cycle);
static ngx_int_t ngx_python_postconfiguration(ngx_conf_t *cf);
static wchar_t *python_exec = NULL;
static PyThreadState *main_thread_state = NULL;
static ngx_thread_pool_t *python_thread_pool = NULL;
static ngx_str_t python_thread_pool_str = ngx_string("python_threads");
static ngx_str_t default_str = ngx_string("default");


static void *ngx_http_python_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_wsgi_pass(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_python_path(ngx_conf_t *cf, ngx_command_t *cmd, 
    void *conf);
static char *python_asgi_pass(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static void *ngx_python_create_main_conf(ngx_conf_t *cf);
static void python_thread_dumy(void *data, ngx_log_t *log);
static void python_thread_done(ngx_event_t *ev);


typedef struct {
    ngx_str_t python_path;
} ngx_http_python_main_conf_t;

typedef struct 
{
    void *task_ptr;
    ngx_event_handler_pt  inner_handler;
} python_thread_ctx_t;


static ngx_command_t  ngx_python_commands[] = {
    { ngx_string("python_path"),
        NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
        ngx_http_python_path,
        NGX_HTTP_MAIN_CONF_OFFSET,
        0,
        NULL
    },
    { ngx_string("wsgi_pass"),
        NGX_HTTP_LOC_CONF|NGX_HTTP_LIF_CONF|NGX_HTTP_LMT_CONF|NGX_CONF_TAKE1,
        ngx_http_wsgi_pass,
        NGX_HTTP_LOC_CONF_OFFSET,
        0,
        NULL,
    },
    { ngx_string("asgi_pass"),
        NGX_HTTP_LOC_CONF|NGX_HTTP_LIF_CONF|NGX_HTTP_LMT_CONF|NGX_CONF_TAKE12,
        python_asgi_pass,
        NGX_HTTP_LOC_CONF_OFFSET,
        0,
        NULL,
    },

    ngx_null_command
};


static ngx_http_module_t  ngx_python_module_ctx  = {
    NULL,                                  /* preconfiguration */
    ngx_python_postconfiguration,          /* postconfiguration */

    ngx_python_create_main_conf,           /* create main configuration */
    NULL,                                  /* init main configuration */

    NULL,                                  /* create server configuration */
    NULL,                                  /* merge server configuration */

    ngx_http_python_create_loc_conf,         /* create location configuration */
    NULL                                   /* merge location configuration */
};


ngx_module_t  ngx_python_module = {
        NGX_MODULE_V1,
        &ngx_python_module_ctx,                /* module context */
        ngx_python_commands,                   /* module directives */
        NGX_HTTP_MODULE,                       /* module type */
        NULL,                                  /* init master */
        NULL,                                  /* init module */
        ngx_python_init_process,               /* init process */
        NULL,                                  /* init thread */
        NULL,                                  /* exit thread */
        ngx_python_exit_process,               /* exit process */
        NULL,                                  /* exit master */
        NGX_MODULE_V1_PADDING
};

ngx_int_t ngx_python_notify(ngx_event_handler_pt evt_handler){
    if (!python_thread_pool) {
        return ngx_notify(evt_handler);
    }

    ngx_thread_task_t *task 
        = calloc(sizeof(ngx_thread_task_t) + sizeof(python_thread_ctx_t), 1);
    if (task == NULL) {
        return NGX_ERROR;
    }

    python_thread_ctx_t *ctx = (python_thread_ctx_t *)(task + 1);
    ctx->task_ptr = task;
    ctx->inner_handler = evt_handler;

    task->handler = python_thread_dumy;
    task->event.handler = python_thread_done;
    task->event.data = ctx;

    if (ngx_thread_task_post(python_thread_pool, task) != NGX_OK) {
        return NGX_ERROR;
    }

    return NGX_OK;
}


static ngx_int_t
ngx_python_init_process(ngx_cycle_t *cycle) {
    python_thread_pool = ngx_thread_pool_get(cycle, &python_thread_pool_str);
    if (!python_thread_pool) {
        ngx_log_error(NGX_LOG_INFO, cycle->log, 0,
                  "use default thread pool");
        python_thread_pool = ngx_thread_pool_get(cycle, &default_str);
    }
    if (!python_thread_pool) {
        ngx_log_error(NGX_LOG_WARN, cycle->log, 0,
            "failed to get default thread pool, ngx_notify used,"
            " which is not thread safe");
    }

    ngx_int_t ret;
    if (python_exec == NULL) {
        python_exec = Py_DecodeLocale(PYTHON_EXEC, NULL);
        if (python_exec == NULL) {
            ngx_log_error(NGX_LOG_CRIT, cycle->log, 0,
                          "Could not decode Python executable path.");
            return NGX_ERROR;
        }
    }
    Py_SetProgramName(python_exec);
    if (PyImport_AppendInittab("nginx._nginx", PyInit__nginx) == -1) {
        ngx_log_error(NGX_LOG_CRIT, cycle->log, 0,
                      "Could not initialize nginxpy extension.");
        return NGX_ERROR;
    }
    ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0,
                  "Initializing Python...");
    Py_InitializeEx(0);
    if (!PyEval_ThreadsInitialized()) {
        PyEval_InitThreads();
    }
    if (PyImport_ImportModule("nginx._nginx") == NULL) {
        ngx_log_error(NGX_LOG_CRIT, cycle->log, 0,
                      "Could not import nginxpy extension.");
        return NGX_ERROR;
    }
    
    ret = nginxpy_init_process(cycle);
    main_thread_state = PyEval_SaveThread();
    return ret;
}

static void
ngx_python_exit_process(ngx_cycle_t *cycle) {
    PyEval_RestoreThread(main_thread_state);
    nginxpy_exit_process(cycle);
    ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0,
                  "Finalizing Python...");
    if (Py_FinalizeEx() < 0) {
        ngx_log_error(NGX_LOG_CRIT, cycle->log, 0,
                      "Failed to finalize Python!");
    }
}

static ngx_int_t
ngx_python_postconfiguration(ngx_conf_t *cf) {
    // ngx_http_handler_pt        *h;
    // ngx_http_core_main_conf_t  *cmcf;
    ngx_http_python_main_conf_t *pmcf;

    // removed here, planing to support this functionality by explicit configuration
    // cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);
    // h = ngx_array_push(&cmcf->phases[NGX_HTTP_POST_READ_PHASE].handlers);
    // if (h == NULL) {
    //     return NGX_ERROR;
    // }
    // *h = nginxpy_post_read;

    // set python path
    pmcf = ngx_http_conf_get_module_main_conf(cf, ngx_python_module);
    if (pmcf && pmcf->python_path.len) {
        wchar_t *python_path = Py_DecodeLocale((char *)pmcf->python_path.data, 
            NULL);
        Py_SetPath(python_path);
        ngx_log_error(NGX_LOG_NOTICE, cf->cycle->log, 0,
                  "set python path to: %s", pmcf->python_path.data);
        PyMem_RawFree(python_path);
    }

    return NGX_OK;
}

static void *
ngx_python_create_main_conf(ngx_conf_t *cf){
    ngx_http_python_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_python_main_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    return conf;
}

static void *
ngx_http_python_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_python_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_python_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    return conf;
}


static char *
ngx_http_python_path(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_python_main_conf_t *pmcf = conf;
    ngx_str_t *value;

    if (!pmcf) {
        return "create python path failed";
    }

    if (pmcf->python_path.len != 0) {
        return "is duplicate";
    }

    value = cf->args->elts;
    pmcf->python_path.len = value[1].len;
    pmcf->python_path.data = value[1].data;

    return NGX_CONF_OK;
}

static char *
python_asgi_pass(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_python_loc_conf_t *plcf = conf;
    ngx_http_core_loc_conf_t *clcf;
    ngx_str_t *value;

    if (plcf->asgi_pass.len != 0) {
        return "is duplicate";
    }

    value = cf->args->elts;
    plcf->asgi_pass.len = value[1].len;
    plcf->asgi_pass.data = value[1].data;
    ngx_log_error(NGX_LOG_DEBUG, cf->cycle->log, 0,
        "add asgi app: %s", value[1].data);

    if (cf->args->nelts >= 3) {
        plcf->version = ngx_atoi(value[2].data, value[2].len);
    }

    /*  register location content handler */
    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    if (clcf == NULL) {
        return NGX_CONF_ERROR;
    }
    clcf->handler = ngx_http_python_asgi_handler;

    return NGX_CONF_OK;
}


static char *
ngx_http_wsgi_pass(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_python_loc_conf_t *plcf = conf;
    plcf->is_wsgi = 1;

    return python_asgi_pass(cf, cmd, conf);
}

static void 
python_thread_dumy(void *data, ngx_log_t *log) {
    return;
}

static void
python_thread_done(ngx_event_t *ev) {
    python_thread_ctx_t *ctx = ev->data;
    ctx->inner_handler(ev);
    free(ctx->task_ptr);
}
