import importlib

def import_by_path(path):
    """
    Given a dotted/colon path, like project.module:ClassName.callable,
    returns the object at the end of the path.
    """
    module_path, object_path = path.split(":", 1)
    target = importlib.import_module(module_path)
    for bit in object_path.split("."):
        target = getattr(target, bit)
    return target

class Asgi2ToAsgi3:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        instance = self.app(scope)
        await instance(receive, send)