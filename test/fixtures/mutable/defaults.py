# Fixture for the Python mutable-default-argument (shared-state) safety rule.
# Only a list [] or dict {} literal default is mutable-and-shared; an empty
# tuple () is IMMUTABLE, and =None / a numeric default are the safe patterns.

def with_list(items=[]):
    items.append(1)
    return items

def with_dict(cache={}):
    return cache

def with_tuple(seen=()):
    return seen

def with_none(cache=None):
    if cache is None:
        cache = []
    return cache

def with_number(limit=10):
    return limit
