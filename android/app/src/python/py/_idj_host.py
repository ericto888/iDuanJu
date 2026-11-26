# -*- coding: utf-8 -*-
"""Native half of HOST_ABI.md for Python spiders on Android (Chaquopy)."""
from java import jclass

_Host = jclass('app.iduanju.tvbox.runtime.PyHost')


def call(name, args_json):
    return _Host.call(name, args_json)
