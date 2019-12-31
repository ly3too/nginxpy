from .nginx_core cimport ngx_str_t, ngx_module_t, ngx_log_t, ngx_list_t,\
    ngx_chain_t, ngx_int_t, ngx_uint_t, ngx_pool_t


cdef extern from "ngx_http.h":
    ctypedef struct ngx_connection_t:
        ngx_log_t *log

    ctypedef struct ngx_http_headers_in_t:
        ngx_list_t headers

    ctypedef struct ngx_http_headers_out_t:
        ngx_uint_t status
        ngx_str_t content_type
        ngx_list_t headers

    ctypedef struct ngx_http_request_body_t:
        ngx_chain_t *bufs

    ctypedef struct ngx_http_request_t:
        ngx_connection_t *connection
        ngx_str_t request_line
        ngx_str_t uri
        ngx_str_t args
        ngx_str_t exten
        ngx_str_t unparsed_uri
        ngx_str_t method_name
        ngx_str_t http_protocol
        ngx_http_headers_in_t headers_in
        ngx_http_headers_out_t headers_out
        unsigned short http_major
        unsigned short http_minor
        ngx_http_request_body_t *request_body
        ngx_pool_t *pool

    ctypedef void (*ngx_http_client_body_handler_pt)(ngx_http_request_t *r)

    void ngx_http_core_run_phases(ngx_http_request_t *request) nogil
    void *ngx_http_get_module_ctx(ngx_http_request_t *request,
                                  ngx_module_t module)
    void ngx_http_set_ctx(ngx_http_request_t *request, void *ctx,
                          ngx_module_t module)
    
    void *ngx_http_get_module_loc_conf(ngx_http_request_t *r, 
        ngx_module_t module)
        
    void *ngx_http_get_module_main_conf(ngx_http_request_t *r, 
        ngx_module_t module)

    void ngx_http_finalize_request(ngx_http_request_t *, ngx_int_t) nogil

    ngx_int_t ngx_http_send_header(ngx_http_request_t *) nogil

    ngx_int_t ngx_http_output_filter(ngx_http_request_t *, ngx_chain_t *) nogil

    ngx_int_t ngx_http_read_client_request_body(ngx_http_request_t *r,
        ngx_http_client_body_handler_pt post_handler) nogil

    const int NGX_HTTP_INTERNAL_SERVER_ERROR
    const int NGX_HTTP_SPECIAL_RESPONSE