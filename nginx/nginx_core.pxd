from cpython.bytes cimport PyBytes_FromStringAndSize
from .nginx_config cimport ngx_int_t, ngx_uint_t


cdef extern from "ngx_core.h":
    const ngx_int_t NGX_OK
    const ngx_int_t NGX_ERROR
    const ngx_int_t NGX_DECLINED
    const ngx_int_t NGX_AGAIN
    const ngx_int_t NGX_DONE

    const int NGX_LOG_EMERG
    const int NGX_LOG_ALERT
    const int NGX_LOG_CRIT
    const int NGX_LOG_ERR
    const int NGX_LOG_WARN
    const int NGX_LOG_NOTICE
    const int NGX_LOG_INFO
    const int NGX_LOG_DEBUG

    ctypedef int ngx_err_t
    ctypedef int ngx_msec_t

    ctypedef unsigned char u_char

    ctypedef struct ngx_str_t:
        size_t len
        char *data

    ctypedef struct ngx_module_t:
        pass

    ctypedef struct ngx_log_t:
        pass

    ctypedef struct ngx_cycle_t:
        ngx_log_t *log

    ctypedef struct ngx_queue_t:
        ngx_queue_t *prev
        ngx_queue_t *next

    void *ngx_calloc(size_t size, ngx_log_t *log)
    void ngx_free(void *p)
    void ngx_log_error(ngx_uint_t level,
                       ngx_log_t *log,
                       ngx_err_t err,
                       const char *fmt)

    ctypedef struct ngx_list_part_t:
        void *elts
        ngx_uint_t nelts
        ngx_list_part_t *next

    ctypedef struct ngx_list_t:
        ngx_list_part_t part

    ctypedef struct ngx_table_elt_t:
        ngx_uint_t hash
        ngx_str_t key
        ngx_str_t value
        u_char *lowcase_key

    ctypedef size_t off_t
    ctypedef int ngx_fd_t

    ctypedef struct ngx_file_t:
        ngx_fd_t fd

    ctypedef struct ngx_buf_t:
        u_char *pos
        u_char *last 
        ngx_file_t *file
        off_t file_pos
        off_t file_last
        unsigned last_buf
        unsigned last_in_chain
        unsigned memory
        unsigned in_file

    ctypedef struct ngx_chain_t:
        ngx_buf_t    *buf
        ngx_chain_t  *next

    ctypedef struct ngx_pool_t:
        pass 
    
    void *ngx_palloc(ngx_pool_t *, size_t)

    void ngx_memcpy(void *, void *, size_t)
    void *ngx_cpymem(void *, void *, size_t)

    void *ngx_list_push(ngx_list_t *)

    ngx_buf_t *ngx_create_temp_buf(ngx_pool_t *, size_t)

    int ngx_buf_in_memory(ngx_buf_t *)

cdef inline str from_nginx_str(ngx_str_t str):
    return PyBytes_FromStringAndSize(<char*>str.data,
                                     str.len).decode('iso-8859-1')
