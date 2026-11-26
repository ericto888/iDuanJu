"""multipart/form-data bodies (original implementation for i短剧, GPL-3.0)."""

from _idj_http import multipart


def choose_boundary():
    from os import urandom

    return urandom(16).hex()


class RequestField:
    def __init__(self, name, data, filename=None, headers=None):
        self.name = name
        self.data = data
        self.filename = filename
        self.headers = dict(headers or {})

    @classmethod
    def from_tuples(cls, fieldname, value, **_):
        content_type = filename = None
        if isinstance(value, tuple):
            if len(value) == 3:
                filename, data, content_type = value
            else:
                filename, data = value
        else:
            data = value
        field = cls(fieldname, data, filename)
        if content_type is None and filename is not None:
            import mimetypes

            content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        field.make_multipart(content_type=content_type)
        return field

    def make_multipart(self, content_disposition=None, content_type=None, content_location=None):
        if content_type:
            self.headers["Content-Type"] = content_type


def encode_multipart_formdata(fields, boundary=None):
    """fields: dict or list of (name, value | (filename, data[, type])) or RequestField -> (body, content type)."""
    out = []
    for item in fields.items() if hasattr(fields, "items") else fields:
        field = item if isinstance(item, RequestField) else RequestField.from_tuples(*item)
        data = field.data
        if hasattr(data, "read"):
            data = data.read()
        if isinstance(data, int):
            data = str(data)
        if isinstance(data, str):
            data = data.encode("utf-8")
        headers = dict(field.headers)
        content_type = headers.pop("Content-Type", None)
        out.append((field.name, field.filename, data, content_type, headers))
    return multipart(out, boundary)
