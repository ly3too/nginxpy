extern ngx_module_t ngx_python_module;

typedef struct {
    ngx_str_t asgi_pass;
    int is_wsgi;
    ngx_int_t version;
} ngx_http_python_loc_conf_t;

typedef struct {
    ngx_str_t python_path;
    ngx_str_t executor_conf;
} ngx_http_python_main_conf_t;

/**
 * notify event loop from other thread, 
 * TODO: alternatively, create a ngx_connection to notify event loop
*/
ngx_int_t ngx_python_notify(ngx_event_handler_pt evt_handler);