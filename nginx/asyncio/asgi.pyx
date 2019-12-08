from .ngx_http cimport ngx_http_request_t, ngx_http_get_module_loc_conf
from .utils import import_by_path
import os

cdef get_headers(ngx_http_request_t *r):
"""
get headers from ngx request
"""
    cdef ngx_list_part_t *part = &(r.headers_in.headers.part)
    cdef int i

    headers = list()
    while part:
        for i in range(part.nelts):
            key = from_nginx_str(part.elts[i].key)
            val = from_nginx_str(part.elts[i].value)
            headers.append([key, val])

        part = part.next

    return headers

cdef get_loc_app(ngx_http_request_t *r):
"""
get the app from location config
"""
    ngx_http_python_loc_conf_t *plcf = 
        <ngx_http_python_loc_conf_t *>ngx_http_get_module_loc_conf(r, ngx_python_module)
    app_str = from_nginx_str(plcf.asgi_pass).decode("utf-8")
    app = import_by_path(app_str)

    if is_wsgi:
        # todo: wsgi to asgi adapter
        return None
    
    return app

cdef request_read_post_handler(ngx_http_request_t *request):
"""
read client body and set the in buffer NgxAsgiCtx
"""
    cdef NgxAsgiCtx ctx = NgxAsgiCtx.get_or_set_asgi_ctx(request)

    if request.request_body == NULL:
        return

    ctx.in_chain = request.request_body.bufs

cdef ngx_str_from_bytes(ngx_pool_t *pool, val):
    cdef ngx_str_t ngx_str
    cdef size_t val_len = len(val)
    ngx_str.data = ngx_palloc(pool, val_len)
    if ngx_str.data == NULL:
        raise RuntimeError('bad alloc')
    ngx_memcpy(ngx_str.data, <char *>val, val_len)
    ngx_str.len = val_len
    return ngx_str

cdef int request_send_headers(ngx_http_request_t *r, headers, status):
    r.headers_out.status = int(status)
    for key, val  in headers:
        key = bytes(key)
        val = bytes(val)
        if key.lower() == b'content-type':
            r.headers_out.content_type = ngx_str_from_bytes(val)
            continue

        cdef ngx_table_elt_t *h = ngx_list_push(r.headers_out.headers)
        if h == NULL:
            raise RuntimeError("bad alloc")
        h.hash = 1
        h.key = <ngx_str_t>ngx_str_from_bytes(key)
        h.val = <ngx_str_t>ngx_str_from_bytes(val)
    
    return ngx_http_send_header(r)

cdef ngx_send_body(ngx_http_request_t *r, body, more_body):
    cdef size_t body_len = len(body)
    ngx_buf_t *buf = ngx_create_temp_buf(r.pool, body_len)
    if buf == NULL:
        raise RuntimeError('bad alloc')
    buf.last = ngx_cpy(buf.last, <char *>body, body_len)
    buf.last_buf = not more_body
    buf.last_in_chain = 1
    buf.memory = 1
    
    cdef ngx_chain_t out
    out.buf = buf 
    out.next = NULL
    if ngx_http_output_filter(r, <ngx_chain_t *>out) != NGX_OK:
        raise RuntimeError('failed to send body')


cdef class NgxAsgiCtx:
    cdef public ngx_http_request_t *request
    cdef public ngx_chain_t *in_chain = NULL
    cdef public bool closed = False
    cdef public bool response_started = False
    cdef public bool respense_complete = False
    cdef public ssize_t file_off = -1
    def __cinit__(self, ngx_http_request_t *request):
        self.request = request
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

    async def receive(self):
        if self.closed or self.response_started:
            return {"type": "http.disconnect"}
        
        data = {"type": "http.request", "body": b""}
        if self.in_chain == NULL:
            return data
        
        if self.in_chain.buf and self.in_chain.buf:
            cdef ngx_buf_t *buf = self.in_chain.buf
            body = ""
            if ngx_buf_in_memory(buf):
                body = PyBytes_FromStringAndSize(<char*>buf.pos,
                        buf.last - buf.pos).decode('iso-8859-1')
                self.in_chain = self.in_chain.next
                self.file_off = -1
            elif buf.in_file && buf.in_file not is NULL:
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

            body = message.get("body", b"")
            more_body = message.get("more_body", False)
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
            new_asgi = NgxAsgiCtx(r)
            ngx_http_set_ctx(r, <void *>new_asgi, ngx_python_module)
        else:
            new_asgi = <object>ctx
        return new_asgi

cdef public ngx_int_t ngx_http_python_asgi_handler(ngx_http_request_t *r):
    # create scope
    asgi_ctx =  NgxAsgiCtx.get_or_set_asgi_ctx(r)

    # create app
    

    # put app into loop's task queue

    # return ngx_done