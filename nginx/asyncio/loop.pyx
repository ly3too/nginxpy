from cpython cimport Py_INCREF, Py_DECREF

from .nginx_core cimport ngx_cycle_t, ngx_calloc, ngx_free
from .nginx_event cimport ngx_event_t, ngx_post_event, ngx_add_timer,\
    ngx_event_del_timer, ngx_posted_events, ngx_notify

# import contextvars
import logging
import time
import traceback
import queue
from asyncio import Task, AbstractEventLoopPolicy, Future, futures
import concurrent

log = logging.Logger(__name__)


cdef class Event:
    cdef:
        ngx_event_t *event
        object _callback
        object _args
        object _context
        object _cancled
        object _post_callbacks

    def __cinit__(self, callback, args, context):
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
        self._post_callbacks = []

    def __dealloc__(self):
        ngx_free(self.event)
        self.event = NULL

    @staticmethod
    cdef void _run(ngx_event_t *ev) with gil:
        cdef Event self = <Event> ev.data
        try:
            #self._context.run(self._callback, *self._args)
            if not self._cancled:
                self._callback(*self._args)
        except Exception as exc:
            traceback.print_exc()
        finally:
            # wakeup coroutine suspend for this event
            self.run_post_callbacks()
            Py_DECREF(self)

    def cancel(self):
        self._cancled = True
        if self.event.timer_set:
            ngx_event_del_timer(self.event)
        self.run_post_callbacks()

    cdef call_later(self, float delay):
        ngx_add_timer(self.event, int(delay * 1000))
        Py_INCREF(self)
        return self

    cdef post(self):
        ngx_post_event(self.event, &ngx_posted_events)
        Py_INCREF(self)
        return self

    cdef add_post_callback(self, callback, args):
        self._post_callbacks.append([callback, args])
        return self

    cdef run_post_callbacks(self):
        for callback, args in self._post_callbacks:
            callback(*args)

cdef void _ngx_event_loop_post(ngx_event_t *ev) with gil:
    """post events in loop's event queue
    """
    cdef Event event
    loop = asyncio.get_event_loop()
    while not loop._event_queue.empty():
        try: 
            event = <Event>loop._event_queue.get_nowait()
            event.post()
        except queue.Empty:
            pass

class NginxEventLoop:
    _current_coro = None
    _exception_handler = None
    _default_executor = None
    def __init__(self):
        # used for call_soon_threadsafe
        self._event_queue = queue.Queue()

    def create_task(self, coro):
        return Task(coro, loop=self)

    def create_future(self):
        return Future(loop=self)

    def time(self):
        return time.monotonic()

    def call_later(self, delay, callback, *args, context=None):
        cdef Event event = Event(callback, args, context)
        event.add_post_callback(self._run_coro, [self._current_coro])
        return event.call_later(delay)

    def call_at(self, when, callback, *args, context=None):
        return self.call_later(when - self.time(), callback, *args,
                               context=context)

    def call_soon(self, callback, *args, context=None):
        cdef Event event = Event(callback, args, context)
        event.add_post_callback(self._run_coro, [self._current_coro])
        return event.post()

    def get_debug(self):
        return False

    def set_exception_handler(self, handler):
        self._exception_handler = handler

    def call_exception_handler(self, context):
        if self._exception_handler:
            self._exception_handler(context)

    def call_soon_threadsafe(self, callback, *args):
        if <void *>ngx_notify == NULL:
            raise NotImplementedError
        cdef Event event = Event(callback, args, None)
        self._event_queue.put(event)
        ngx_notify(_ngx_event_loop_post)
        return event

    def run_in_executor(self, executor, func, *args):
        if executor is None:
            executor = self._default_executor
            if executor is None:
                executor = concurrent.futures.ThreadPoolExecutor()
                self._default_executor = executor
        return futures.wrap_future(executor.submit(func, *args), loop=self)

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

    