from .ngx_http cimport ngx_http_request_t, ngx_http_get_module_loc_conf,\
    ngx_http_finalize_request, NGX_HTTP_INTERNAL_SERVER_ERROR,\
    ngx_http_send_header, ngx_http_output_filter,\
    ngx_http_read_client_request_body, NGX_HTTP_SPECIAL_RESPONSE
from .nginx_core cimport ngx_pool_t, ngx_list_part_t, ngx_table_elt_t,\
    ngx_buf_t, ngx_palloc, ngx_memcpy, ngx_list_push, ngx_create_temp_buf,\
    ngx_cpymem, u_char, ngx_buf_in_memory, NGX_DONE, ngx_uint_t
from cpython.bytes cimport PyBytes_FromStringAndSize
from .utils import import_by_path
import os
import asyncio

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
            key = from_nginx_str(h[i].key)
            val = from_nginx_str(h[i].value)
            headers.append([key, val])

        part = part.next

    return headers

cdef get_loc_app(ngx_http_request_t *r):
    """
    get the app from location config
    """
    cdef ngx_http_python_loc_conf_t *plcf = \
        <ngx_http_python_loc_conf_t *>ngx_http_get_module_loc_conf(r, ngx_python_module)
    app_str = from_nginx_str(plcf.asgi_pass).decode("utf-8")
    app = import_by_path(app_str)

    if plcf.is_wsgi:
        # todo: wsgi to asgi adapter
        return None
    
    return app

cdef void request_read_post_handler(ngx_http_request_t *request):
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
    cdef ssize_t file_off
    def __cinit__(self):
        self.in_chain = NULL
        self.closed = False
        self.response_started = False
        self.response_complete = False
        self.request = NULL
        self.file_off = -1

    cdef init(self, ngx_http_request_t *request):
        self.scope = {
            "type": "http",
            "http_version": "{}.{}".format(request.http_major, request.http_minor),
            "method": from_nginx_str(request.method_name).decode("ascii"),
            "path": from_nginx_str(request.uri).decode("ascii"),
            "raw_path": from_nginx_str(request.unparsed_uri), # bytes
            "query_string": from_nginx_str(request.args), # bytes
            "headers": get_headers(request),
        }
        self.app = get_loc_app(request)
        if self.app is None:
            raise RuntimeError("failed to create app")
        self.file_off = -1

    cdef start_app(self):
        self.app_coro = self.app(self.scope, self.receive, self.send)
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
        status = data["status"]
        
        if not self.response_started:
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

cdef public ngx_int_t ngx_http_python_asgi_handler(ngx_http_request_t *r):
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