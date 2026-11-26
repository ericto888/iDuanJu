"""lxml-compatible API for i短剧 spiders on iOS.

Original implementation (GPL-3.0) on top of the host's HTML/XPath functions; not a copy of lxml. Reading and querying
documents is covered, in-place editing only as far as the host offers it (attributes, text of leaf elements, removal).
"""

__version__ = "5.3.0"


def get_include():
    raise NotImplementedError("lxml.get_include(): iOS 版没有 C 头文件")
