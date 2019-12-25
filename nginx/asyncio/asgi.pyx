"""Implementation of asgi and wsgi functionality.

Take advantage of the non-bloking feature of nginx and python3's asyncio.
Try to adapt the nginx request processing phase to python3's event loop.
"""

from .ngx_http cimport ngx_http_request_t, ngx_http_get_module_loc_conf,\
    ngx_http_finalize_request, NGX_HTTP_INTERNAL_SERVER_ERROR,\
    ngx_http_send_header, ngx_http_output_filter,\
    ngx_http_read_client_request_body, NGX_HTTP_SPECIAL_RESPONSE
from .nginx_core cimport ngx_pool_t, ngx_list_part_t, ngx_table_elt_t,\
    ngx_buf_t, ngx_palloc, ngx_memcpy, ngx_list_push, ngx_create_temp_buf,\
    ngx_cpymem, u_char, ngx_buf_in_memory, NGX_DONE, ngx_uint_t,\
    bytes_from_nginx_str, NGX_LOG_ERR, ngx_pool_cleanup_t, ngx_pool_cleanup_add
from cpython.bytes cimport PyBytes_FromStringAndSize
from .utils import import_by_path, Asgi2ToAsgi3
import os
import asyncio
from cpython cimport Py_INCREF, Py_DECREF

# __author__ = 'ly3too@qq.com'
# __copyright__ = "Copyright 2019, ly3too@qq.com"
# __credits__ = []
# __license__ = "Apache 2.0"

cdef get_headers(ngx_http_request_t *r):
    """
    get headers from ngx request
    """
    cdef ngx_list_part_t *part = &(r.headers_in.headers.part)
    cdef ngx_uint_t i
    cdef ngx_table_elt_t *h = <ngx_table_elt_t *>part.elts

    headers = list()
    while part:
        for i in range(part.nelts):
            key = bytes_from_nginx_str(h[i].key)
            val = bytes_from_nginx_str(h[i].value)
            headers.append([key, val])

        part = part.next

    return headers

cdef get_loc_app(ngx_http_request_t *r):
    """
    get the app from location config
    """
    cdef ngx_http_python_loc_conf_t *plcf = \
        <ngx_http_python_loc_conf_t *>ngx_http_get_module_loc_conf(r, ngx_python_module)
    app_str = from_nginx_str(plcf.asgi_pass)
    app = import_by_path(app_str)

    if plcf.is_wsgi:
        # todo: wsgi to asgi adapter
        return None
    
    # asgi2/asgi3
    if plcf.version == 2:
        return Asgi2ToAsgi3(app)
    else:
        return app

cdef void request_read_post_handler(ngx_http_request_t *request) with gil:
    """
    read client body and set the in buffer NgxAsgiCtx
    """
    cdef NgxAsgiCtx ctx
    try:
        ctx = NgxAsgiCtx.get_or_set_asgi_ctx(request)
    except:
        ngx_log_error(NGX_LOG_CRIT, request.connection.log, 0,
                      b'Error occured in post_read:\n' +
                      traceback.format_exc().encode())

    if request.request_body == NULL:
        ngx_http_finalize_request(request, NGX_HTTP_INTERNAL_SERVER_ERROR)
        return

    ctx.in_chain = request.request_body.bufs
    ctx.start_app()

cdef ngx_str_t ngx_str_from_bytes(ngx_pool_t *pool, val):
    cdef ngx_str_t ngx_str
    cdef size_t val_len = len(val)
    ngx_str.data = <u_char *>ngx_palloc(pool, val_len)
    if ngx_str.data == NULL:
        raise RuntimeError('bad alloc')
    ngx_memcpy(ngx_str.data, <char *>val, val_len)
    ngx_str.len = val_len
    return ngx_str

cdef int request_send_headers(ngx_http_request_t *r, headers, status):
    cdef ngx_table_elt_t *h
    r.headers_out.status = int(status)
    for key, val  in headers:
        key = bytes(key)
        val = bytes(val)
        if key.lower() == b'content-type':
            r.headers_out.content_type = ngx_str_from_bytes(r.pool, val)
            continue

        h = <ngx_table_elt_t *>ngx_list_push(&r.headers_out.headers)
        if h == NULL:
            raise RuntimeError("bad alloc")
        h.hash = 1
        h.key = <ngx_str_t>ngx_str_from_bytes(r.pool, key)
        h.value = <ngx_str_t>ngx_str_from_bytes(r.pool, val)
    
    return ngx_http_send_header(r)

cdef ngx_send_body(ngx_http_request_t *r, body, more_body):
    cdef size_t body_len = len(body)
    cdef ngx_buf_t *buf = ngx_create_temp_buf(r.pool, body_len)
    if buf == NULL:
        raise RuntimeError('bad alloc')
    buf.last = <u_char *>ngx_cpymem(buf.last, <char *>body, body_len)
    buf.last_buf = not more_body
    buf.last_in_chain = 1
    buf.memory = 1
    
    cdef ngx_chain_t out
    out.buf = buf 
    out.next = NULL
    if ngx_http_output_filter(r, &out) != NGX_OK:
        raise RuntimeError('failed to send body')


cdef class NgxAsgiCtx:
    cdef ngx_http_request_t *request
    cdef ngx_chain_t *in_chain
    cdef bint closed
    cdef bint response_started
    cdef bint response_complete
    cdef ssize_t file_off
    cdef public object scope
    cdef public object app
    cdef public object app_coro
    def __cinit__(self):
        self.request = NULL
        self.in_chain = NULL
        self.closed = False
        self.response_started = False
        self.response_complete = False
        self.file_off = -1

    @staticmethod
    cdef void clean_up(void *data) with gil:
        cdef NgxAsgiCtx asgi_ctx = <NgxAsgiCtx>data
        Py_DECREF(asgi_ctx)

    cdef init(self, ngx_http_request_t *request):
        Py_INCREF(self)
        cdef ngx_pool_cleanup_t  *cln
        cln = ngx_pool_cleanup_add(request.pool, sizeof(self))
        if cln == NULL:
            Py_DECREF(self)
            raise Exception('failed to add cleanup handler')
        cln.handler = NgxAsgiCtx.clean_up
        cln.data = <void *>self

        self.request = request
        self.scope = {
            "type": "http",
            "http_version": "{}.{}".format(request.http_major, request.http_minor),
            "method": from_nginx_str(request.method_name),
            "path": from_nginx_str(request.uri),
            "raw_path": bytes_from_nginx_str(request.unparsed_uri), # bytes
            "query_string": bytes_from_nginx_str(request.args), # bytes
            "headers": get_headers(request),
        }
        self.app = get_loc_app(request)
        if self.app is None:
            raise RuntimeError("failed to create app")
        self.file_off = -1

    async def _coro_with_exception_handler(self, coro):
        try:
            await coro
        except:
            ngx_log_error(NGX_LOG_ERR, self.request.connection.log, 0,
                      b'App interal error:\n' +
                      traceback.format_exc().encode())
            ngx_http_finalize_request(self.request, 
                NGX_HTTP_INTERNAL_SERVER_ERROR)
        finally:
            if not self.response_complete:
                self.response_complete = True
                ngx_http_finalize_request(self.request, NGX_OK)

    cdef start_app(self):
        ngx_log_error(NGX_LOG_DEBUG, self.request.connection.log, 0, 
            b"start asgi app")
        self.app_coro = self._coro_with_exception_handler(
            self.app(self.scope, self.receive, self.send))
        loop = asyncio.get_event_loop()
        loop._run_coro(self.app_coro)

    async def receive(self):
        cdef ngx_buf_t *buf
        if self.closed or self.response_started:
            return {"type": "http.disconnect"}
        
        data = {"type": "http.request", "body": b""}
        if self.in_chain == NULL:
            return data
        
        if self.in_chain.buf and self.in_chain.buf:
            buf = self.in_chain.buf
            body = ""
            if ngx_buf_in_memory(buf):
                body = PyBytes_FromStringAndSize(<char*>buf.pos,
                        buf.last - buf.pos).decode('iso-8859-1')
                self.in_chain = self.in_chain.next
                self.file_off = -1
            elif buf.in_file:
                if self.file_off < 0:
                    self.file_off = buf.file_pos
                fd = buf.file.fd
                os.lseek(fd, self.file_off, os.SEEK_SET)
                body = os.read(fd, buf.file_last - self.file_off)
                self.file_off += len(body)
                if self.file_off >= buf.file_last:
                    self.in_chain = self.in_chain.next
                    self.file_off = -1
            else:
                self.in_chain = self.in_chain.next
                self.file_off = -1
        
        has_next = self.in_chain is not NULL
        data["body"] = body
        data["more_body"] = has_next
        return data

    async def send(self, data):
        message_type = data["type"]
        
        if not self.response_started:
            status = data["status"]
            # Sending response status line and headers
            if message_type != "http.response.start":
                msg = "Expected ASGI message 'http.response.start', but got '{}'."
                raise RuntimeError(msg.format(message_type))

            self.response_started = True
            headers = list(data.get("headers", []))
            if request_send_headers(self.request, headers, status) != NGX_OK:
                raise RuntimeError('failed to send header')

        elif not self.response_complete:
            # Sending response body
            if message_type != "http.response.body":
                msg = "Expected ASGI message 'http.response.body', but got '%s'."
                raise RuntimeError(msg % message_type)

            body = data.get("body", b"")
            more_body = data.get("more_body", False)
            ngx_send_body(self.request, body, more_body)

            # Handle response completion
            if not more_body:
                self.response_complete = True
                ngx_http_finalize_request(self.request, NGX_OK)      

        else:
            # Response already sent
            msg = "Unexpected ASGI message '%s' sent, after response already completed."
            raise RuntimeError(msg % message_type)
        
    
    @staticmethod
    cdef NgxAsgiCtx get_or_set_asgi_ctx(ngx_http_request_t *r):
        cdef void *ctx
        cdef NgxAsgiCtx new_asgi
        ctx = ngx_http_get_module_ctx(r, ngx_python_module)
        if ctx == NULL:
            new_asgi = NgxAsgiCtx.__new__(NgxAsgiCtx)
            new_asgi.init(r)
            ngx_http_set_ctx(r, <void *>new_asgi, ngx_python_module)
        else:
            new_asgi = <object>ctx
        return new_asgi

cdef public ngx_int_t ngx_http_python_asgi_handler(ngx_http_request_t *r) with gil:
    ngx_log_error(NGX_LOG_DEBUG, r.connection.log, 0, b"entered asgi handler")
    # create scope
    try:
        asgi_ctx =  NgxAsgiCtx.get_or_set_asgi_ctx(r)
    except:
        ngx_log_error(NGX_LOG_CRIT, r.connection.log, 0,
                      b'Error occured in post_read:\n' +
                      traceback.format_exc().encode())
        return NGX_HTTP_INTERNAL_SERVER_ERROR

    # receive content and start app
    cdef ngx_int_t rc = ngx_http_read_client_request_body(r, 
        request_read_post_handler)
    if rc == NGX_ERROR or rc >= NGX_HTTP_SPECIAL_RESPONSE:
        return rc

    return NGX_DONE