extern ngx_module_t ngx_python_module;

typedef struct {
    ngx_str_t asgi_pass;
    int is_wsgi;
} ngx_http_python_loc_conf_t;
