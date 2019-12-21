from cpython cimport Py_INCREF, Py_DECREF

from .nginx_core cimport ngx_cycle_t, ngx_calloc, ngx_free
from .nginx_event cimport ngx_event_t, ngx_post_event, ngx_add_timer
from .nginx_event cimport ngx_posted_events

# import contextvars
import logging
import time
import traceback
from asyncio import Task, AbstractEventLoopPolicy, Future

log = logging.Logger(__name__)


cdef class Event:
    cdef:
        ngx_event_t *event
        object _callback
        object _args
        object _context

    def __cinit__(self, loop, callback, args, context, coro = None):
        self.event = <ngx_event_t *> ngx_calloc(sizeof(ngx_event_t),
                                                current_cycle.log.log)
        self.event.log = current_cycle.log.log
        self.event.data = <void *> self
        self.event.handler = self._run
        self._callback = callback
        self._args = args
        #if context is None:
        #    context = contextvars.copy_context()
        self._context = context
        self._cancled = False
        self._post_callback = None
        self._post_args = None

    def __dealloc__(self):
        ngx_free(self.event)
        self.event = NULL

    @staticmethod
    cdef void _run(ngx_event_t *ev):
        cdef Event self = <Event> ev.data
        try:
            #self._context.run(self._callback, *self._args)
            if not self._cancled:
                self._callback(*self._args)
        except Exception as exc:
            traceback.print_exc()
        finally:
            # wakeup coroutine suspend for this event
            if self._post_callback:
                self._post_callback(*self._post_args)
            Py_DECREF(self)

    def cancel(self):
        self._cancled = True

    cdef call_later(self, float delay):
        ngx_add_timer(self.event, int(delay * 1000))
        Py_INCREF(self)
        return self

    cdef post(self):
        ngx_post_event(self.event, &ngx_posted_events)
        Py_INCREF(self)
        return self

    cdef add_post_callback(self, callback, args):
        self._post_callback = callback
        self._post_args = args


cdef class NginxEventLoop:
    _current_coro = None
    def create_task(self, coro):
        return Task(coro, loop=self)

    def create_future(self):
        return Future(loop=self)

    def time(self):
        return time.monotonic()

    def call_later(self, delay, callback, *args, context=None):
        return Event(callback, args, context)\
            .add_post_callback(self._run_coro, self._current_coro)\
            .call_later(delay)

    def call_at(self, when, callback, *args, context=None):
        return self.call_later(when - self.time(), callback, *args,
                               context=context)

    def call_soon(self, callback, *args, context=None):
        return Event(callback, args, context)\
            .add_post_callback(self._run_coro, self._current_coro).post()

    def get_debug(self):
        return False

    def set_exception_handler(self, handler):
        self._exception_handler = handler

    def call_exception_handler(self, context):
        if self._exception_handler:
            self._exception_handler(context)

    def _run_coro(self, coro):
        """
        schedule a top coroutine
        """
        if coro is None:
            return
        try:
            self._current_coro = coro
            coro.send(None)
        except StopIteration as e:
            context = {
                "message": "",
                "exception": e
            }
            self.call_exception_handler(context)
        except Exception as e:
            context = {
                "message": "exception raised from coroutine",
                "exception": e
            }
            self.call_exception_handler(context)
        finally:
            self._current_coro = None


class NginxEventLoopPolicy(AbstractEventLoopPolicy):
    def __init__(self):
        self._loop = NginxEventLoop()

    def get_event_loop(self):
        return self._loop

    def set_event_loop(self, loop) -> None:
        pass

    def new_event_loop(self):
        return self._loop

    