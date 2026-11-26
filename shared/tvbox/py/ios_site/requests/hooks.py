"""Response hooks (original implementation for i短剧, GPL-3.0)."""

HOOKS = ["response"]


def default_hooks():
    return {event: [] for event in HOOKS}


def dispatch_hook(key, hooks, hook_data, **kwargs):
    chain = (hooks or {}).get(key)
    if callable(chain):
        chain = [chain]
    for hook in chain or ():
        result = hook(hook_data, **kwargs)
        if result is not None:
            hook_data = result
    return hook_data
