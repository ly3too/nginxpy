=======
NGINXpy
=======


.. image:: https://img.shields.io/pypi/v/nginxpy.svg
        :target: https://pypi.python.org/pypi/nginxpy

.. image:: https://img.shields.io/travis/decentfox/nginxpy.svg
        :target: https://travis-ci.org/decentfox/nginxpy

.. image:: https://readthedocs.org/projects/nginxpy/badge/?version=latest
        :target: https://nginxpy.readthedocs.io/en/latest/?badge=latest
        :alt: Documentation Status


.. image:: https://pyup.io/repos/github/decentfox/nginxpy/shield.svg
     :target: https://pyup.io/repos/github/decentfox/nginxpy/
     :alt: Updates



Embed Python in NGINX, supporting ASGI, WSGI

forked from https://github.com/decentfox/nginxpy


* Free software: Apache Software License 2.0
* Documentation: https://nginxpy.readthedocs.io.

.. contents:: Overview
   :depth: 3

Features
--------

* Standard Python package with Cython extension
* Automatically build into NGINX dynamic module for current NGINX install
* Run embeded Python in NGINX worker processes
* Write NGINX modules in Python or Cython
* Python ``logging`` module redirected to NGINX ``error.log``
* (ongoing) NGINX event loop wrapped as Python ``asyncio`` interface
* (ongoing) Asgi support. Currently can run some simple app. More works needs to be done to support full featured asgi application.
* (ongoing) WSGI support by WSGI to ASGI adapting. Run wsgi app in thread pool.
* (ongoing) fix memory leak and add more test.
* (TBD) websocket support for asgi and wsgi.
* (TBD) Python and Cython interface to most NGINX code

Installation
------------

1. Install NGINX in whatever way, make sure ``nginx`` command is available.
2. ``pip install nginxpy``, or get the source and run ``pip install .``. You
   may want to add the ``-v`` option, because the process is a bit slow
   downloading Cython, NGINX source code and configuring it. The usual ``python
   setup.py install`` currently doesn't work separately - you should run
   ``python setup.py build`` first.
3. Run ``python -c 'import nginx'`` to get NGINX configuration hint.
4. Update NGINX configuration accordingly and reload NGINX.
5. Visit your NGINX site, see NGINX ``error.log`` for now.

Usage
-----------
By example configuration:

.. code-block:: shell
    http {
        # python_path specifies pathes to search from (PYTHONPATH), before python initinallization. 
        # if not specified, the default PYTHONPATH is used
        python_path "/usr/lib/python3.6:/usr/lib/python3.6/lib-dynload";

        server {
            listen 80;
            location / {
                # same as openresty's content_by_xx. handle request by asgi app
                asgi_pass asgi_helloworld:app;
            }
            location /wsgi {
                # still ongoing
                wsgi_pass wsgi_app:app;
            }
        }
    }


The asgi_helloworld app: 

.. code-block:: python
    import asyncio

    async def app(scope, recevie, send):
        data = await recevie()
        await send({
            "type": "http.response.start",
            "status":200,
            "headers": []
        })
        await send({
            "type": "http.response.body",
            "body": b"Hello World!\n" + str(data).encode() + b"\n",
            "more_body": True
        })
        await asyncio.sleep(5)
        await send({
            "type": "http.response.body",
            "body": str(scope).encode()
        })


Development
-----------

1. Install NGINX in whatever way, make sure ``nginx`` command is available.
2. Checkout source code.
3. Run ``python setup.py build && python setup.py develop``.
4. Run ``python -c 'import nginx'`` to get NGINX configuration hint.
5. Update NGINX configuration accordingly and reload NGINX.
6. Visit your NGINX site, see NGINX ``error.log`` for now.
7. Change code if result is not satisfying, or else go for pull request.
8. Goto 3 if Cython code was changed, or else goto 5.

Surprisingly NGINX has a very simple but powerful architecture, learn about it
here: http://nginx.org/en/docs/dev/development_guide.html


Credits
-------

This package was created with Cookiecutter_ and the `audreyr/cookiecutter-pypackage`_ project template.

.. _Cookiecutter: https://github.com/audreyr/cookiecutter
.. _`audreyr/cookiecutter-pypackage`: https://github.com/audreyr/cookiecutter-pypackage
