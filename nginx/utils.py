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