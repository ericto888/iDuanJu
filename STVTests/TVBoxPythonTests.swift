import XCTest
@testable import STV

/// The embedded CPython (PythonRuntime) with a stand-in runner, so these tests do not depend on shared/tvbox/py.
/// Skipped in builds without the runtime (IDJ_PYTHON=0).
final class TVBoxPythonTests: XCTestCase {
    private static let runner = "idj_test_runner"
    private let host = RecordingHost()
    private var keys: [String] = []
    private var previousHost: PythonRuntime.Host?

    private var runtime: PythonRuntime { .shared }

    override func setUp() async throws {
        guard PythonRuntime.isAvailable else { throw XCTSkip(PythonRuntime.missingMessage) }
        previousHost = runtime.host
        let h = host
        runtime.setHost { h.call($0, $1, $2) }
        let stub = Bundle(for: Self.self).bundlePath + "/Fixtures/python_stub"
        XCTAssertTrue(FileManager.default.fileExists(atPath: stub + "/idj_test_runner.py"))
        try await runtime.addSearchPath(stub)
    }

    override func tearDown() async throws {
        for k in keys { runtime.unload(key: k) }
        if let previousHost { runtime.setHost(previousHost) }
    }

    // MARK: Helpers

    @discardableResult
    private func load(_ body: String, key: String = UUID().uuidString, ext: String = "", timeout: TimeInterval = 20) async throws -> String {
        keys.append(key)
        try await runtime.load(key: key, source: body, ext: ext, timeout: timeout, runner: Self.runner)
        return key
    }

    private func call(_ key: String, _ method: String, _ args: [Any] = [], timeout: TimeInterval = 20) async throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return try await runtime.call(key: key, method: method, argsJSON: json, timeout: timeout)
    }

    private func eval(_ code: String) async throws -> String {
        let indented = code.split(separator: "\n", omittingEmptySubsequences: false).map { "        " + $0 }.joined(separator: "\n")
        let key = try await load("class Spider:\n    def run(self):\n\(indented)\n")
        return try await call(key, "run")
    }

    private func error(_ body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: Interpreter

    func testVersionAndConfiguration() async throws {
        let v = try XCTUnwrap(runtime.version)
        XCTAssertTrue(v.hasPrefix("3.13."), v)
        let r = try await eval("""
        import sys, os
        return [sys.platform, sys.flags.utf8_mode, sys.flags.isolated, sys.flags.no_user_site, sys.dont_write_bytecode,
                os.path.dirname(sys.executable), sys.getfilesystemencoding(), [p for p in sys.path if p.endswith(("/tvbox/py", "ios_site"))]]
        """)
        let a = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.utf8)) as? [Any])
        XCTAssertEqual(a[0] as? String, "ios")
        XCTAssertEqual(a[1] as? Int, 1)
        XCTAssertEqual(a[2] as? Int, 1)
        XCTAssertEqual(a[4] as? Bool, true)
        XCTAssertEqual(a[5] as? String, Bundle.main.bundlePath)
        XCTAssertEqual(a[6] as? String, "utf-8")
        XCTAssertEqual((a[7] as? [String])?.map { $0.replacingOccurrences(of: Bundle.main.bundlePath, with: "") }, ["/tvbox/py", "/tvbox/py/ios_site"])
    }

    func testStandardLibraryImports() async throws {
        let r = try await eval("""
        import importlib
        bad = {}
        for name in ('json re hashlib hmac base64 zlib gzip bz2 lzma datetime zoneinfo time calendar struct random secrets string math cmath '
                     'statistics decimal fractions unicodedata html html.parser html.entities xml.etree.ElementTree xml.dom.minidom xml.sax '
                     'threading queue concurrent.futures concurrent.futures.thread asyncio urllib.parse urllib.request urllib.error http.client '
                     'http.cookiejar http.cookies http.server socket select selectors csv io os os.path sys shutil tempfile pathlib glob fnmatch '
                     'collections collections.abc itertools functools operator copy copyreg pickle pprint types typing enum dataclasses abc '
                     'contextlib contextvars weakref inspect traceback warnings logging logging.handlers argparse configparser uuid ctypes '
                     'ctypes.util binascii codecs locale gettext difflib textwrap ast tokenize dis timeit platform sysconfig zipfile tarfile '
                     'mimetypes email email.mime.text ipaddress heapq bisect array numbers unittest unittest.mock importlib.util importlib.resources '
                     'importlib.metadata quopri signal sched getpass tomllib plistlib encodings.idna encodings.punycode stringprep '
                     'subprocess ftplib smtplib zipimport pkgutil runpy symtable netrc socketserver optparse fileinput').split():
            try:
                importlib.import_module(name)
            except BaseException as e:
                bad[name] = repr(e)
        return bad
        """)
        XCTAssertEqual(r, "{}")
    }

    func testStandardLibraryWorks() async throws {
        let r = try await eval(#"""
        import json, re, hashlib, hmac, base64, zlib, gzip, bz2, lzma, datetime, zoneinfo, struct, random, unicodedata, decimal, urllib.parse
        import xml.etree.ElementTree as ET
        from html.parser import HTMLParser
        out = {}
        out['json'] = json.loads(json.dumps({'a': [1, 2.5, None, '中']}, ensure_ascii=False))['a'][3]
        out['re'] = re.findall(r'(\d+)-(\w+)', '12-ab 34-中文')
        out['md5'] = hashlib.md5('中文'.encode()).hexdigest()
        out['sha'] = [hashlib.new(n, b'abc').hexdigest()[:8] for n in ('sha1', 'sha224', 'sha256', 'sha384', 'sha512', 'sha3_256', 'blake2b', 'blake2s')]
        out['hmac'] = hmac.new(b'key', b'msg', hashlib.sha256).hexdigest()[:8]
        data = b'hello ' * 100
        out['zip'] = all(m.decompress(m.compress(data)) == data for m in (zlib, gzip, bz2, lzma)) and zlib.decompressobj(-15) is not None
        out['date'] = datetime.datetime(2026, 1, 2, 3, 4, 5, tzinfo=datetime.timezone.utc).isoformat()
        out['strptime'] = datetime.datetime.strptime('2026-11-25 10:00', '%Y-%m-%d %H:%M').timetuple().tm_yday
        out['zone'] = datetime.datetime(2026, 1, 1, tzinfo=zoneinfo.ZoneInfo('Asia/Shanghai')).utcoffset().total_seconds()
        out['struct'] = struct.unpack('>IH', struct.pack('>IH', 1, 2))
        random.seed(1); out['random'] = random.randint(1, 100) == 18
        out['nfkc'] = unicodedata.normalize('NFKC', 'ｆｕｌｌ')
        out['gbk'] = ['中文'.encode(c).hex() for c in ('gbk', 'gb18030', 'gb2312', 'big5', 'utf-16le')] + [b'\xd6\xd0\xce\xc4'.decode('GBK')]
        out['quote'] = urllib.parse.quote('中 文/') + urllib.parse.urljoin('http://a/b/c', '../d?x=1') + str(urllib.parse.parse_qs('a=1&a=2'))
        out['xml'] = [e.text for e in ET.fromstring('<r><i>1</i><i>二</i></r>').findall('i')]
        class P(HTMLParser):
            t = []
            def handle_starttag(self, tag, attrs): self.t.append((tag, dict(attrs).get('href', '')))
        p = P(); p.feed('<div><a href="/x?a=1&amp;b=2">x</a></div>'); out['html'] = p.t
        out['b64'] = base64.b64encode(b'\x00\xff').decode()
        out['dec'] = str(decimal.Decimal('1.10') * 3)
        out['idna'] = 'bücher.example'.encode('idna').decode()
        return out
        """#)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any])
        XCTAssertEqual(o["json"] as? String, "中")
        XCTAssertEqual(o["re"] as? [[String]], [["12", "ab"], ["34", "中文"]])
        XCTAssertEqual(o["md5"] as? String, "a7bac2239fcdcb3a067903d8077c4a07")
        XCTAssertEqual(o["sha"] as? [String], ["a9993e36", "23097d22", "ba7816bf", "cb00753f", "ddaf35a1", "3a985da7", "ba80a53f", "508c5e8c"])
        XCTAssertEqual(o["hmac"] as? String, "2d93cbc1")
        XCTAssertEqual(o["zip"] as? Bool, true)
        XCTAssertEqual(o["date"] as? String, "2026-01-02T03:04:05+00:00")
        XCTAssertEqual(o["strptime"] as? Int, 329)
        XCTAssertEqual(o["zone"] as? Double, 28800)
        XCTAssertEqual(o["struct"] as? [Int], [1, 2])
        XCTAssertEqual(o["random"] as? Bool, true)
        XCTAssertEqual(o["nfkc"] as? String, "full")
        XCTAssertEqual(o["gbk"] as? [String], ["d6d0cec4", "d6d0cec4", "d6d0cec4", "a4a4a4e5", "2d4e8765", "中文"])
        XCTAssertEqual(o["quote"] as? String, "%E4%B8%AD%20%E6%96%87/http://a/d?x=1{'a': ['1', '2']}")
        XCTAssertEqual(o["xml"] as? [String], ["1", "二"])
        XCTAssertEqual(o["html"] as? [[String]], [["div", ""], ["a", "/x?a=1&b=2"]])
        XCTAssertEqual(o["b64"] as? String, "AP8=")
        XCTAssertEqual(o["dec"] as? String, "3.30")
        XCTAssertEqual(o["idna"] as? String, "xn--bcher-kva.example")
    }

    /// Every extension module of the bundle loads (its framework, its placeholder and its dependencies are right).
    func testEveryBundledExtensionModuleLoads() async throws {
        let dir = Bundle.main.bundlePath + "/python/lib/python3.13/lib-dynload"
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).map { String($0.prefix { $0 != "." }) }.sorted()
        XCTAssertGreaterThan(names.count, 30)
        let r = try await eval("""
        import importlib, sys
        out = {}
        for name in \(names):
            try:
                m = importlib.import_module(name)
                if not m.__file__.endswith('.fwork') or '/Frameworks/' not in m.__spec__.origin: out[name] = m.__spec__.origin
            except BaseException as e:
                out[name] = repr(e)
        return out
        """)
        XCTAssertEqual(r, "{}")
        // No loose dynamic libraries, every framework has the layout iOS expects.
        let frameworks = Bundle.main.bundlePath + "/Frameworks"
        for n in names + ["Python"] {
            let plist = try XCTUnwrap(NSDictionary(contentsOfFile: "\(frameworks)/\(n).framework/Info.plist"), n)
            XCTAssertEqual(plist["CFBundleExecutable"] as? String, n)
            XCTAssertEqual(plist["CFBundlePackageType"] as? String, "FMWK")
            XCTAssertNotNil((plist["CFBundleIdentifier"] as? String)?.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression))
        }
        let loose = try FileManager.default.subpathsOfDirectory(atPath: Bundle.main.bundlePath + "/python").filter { $0.hasSuffix(".so") || $0.hasSuffix(".dylib") }
        XCTAssertEqual(loose, [])
    }

    func testAsyncioAndConcurrentFutures() async throws {
        let r = try await eval("""
        import asyncio, concurrent.futures as cf
        async def work(i):
            await asyncio.sleep(0.01)
            return i * i
        async def main():
            loop = asyncio.get_running_loop()
            return await asyncio.gather(*[work(i) for i in range(4)], loop.run_in_executor(None, lambda: 'executor'))
        with cf.ThreadPoolExecutor(4) as ex:
            squares = sorted(f.result() for f in cf.as_completed([ex.submit(pow, i, 2) for i in range(5)]))
        return [asyncio.run(main()), squares]
        """)
        XCTAssertEqual(r, #"[[0, 1, 4, 9, "executor"], [0, 1, 4, 9, 16]]"#)
    }

    // MARK: Host

    func testHostRoundTrip() async throws {
        let key = try await load("""
        import _idj_host, json
        class Spider:
            def init(self, ext): self.ext = ext
            def echo(self, x):
                r = json.loads(_idj_host.call('echo', json.dumps({'x': x, 'ext': self.ext}, ensure_ascii=False)))
                return [r['v'], _idj_host.get_key()]
        """, key: "站点 键/1", ext: #"{"a":"扩展"}"#)
        let r = try await call(key, "echo", ["文😀"])
        XCTAssertEqual(r, #"[{"x": "文😀", "ext": "{\"a\":\"扩展\"}"}, "站点 键/1"]"#)
        XCTAssertEqual(host.calls.filter { $0.name == "echo" }.map(\.key), ["站点 键/1"])
        XCTAssertFalse(host.calls.contains { $0.onMainThread })
    }

    func testHostCallFromWorkerThreadsKeepsTheKey() async throws {
        let key = try await load("""
        import _idj_host, json, threading
        from concurrent.futures import ThreadPoolExecutor
        class Spider:
            def run(self):
                def one(i): return [json.loads(_idj_host.call('echo', json.dumps({'i': i})))['v']['i'], _idj_host.get_key(), threading.current_thread().name[:3]]
                with ThreadPoolExecutor(4, thread_name_prefix='w') as ex: return list(ex.map(one, range(8)))
            def keys(self):
                _idj_host.set_key('other'); a = _idj_host.get_key()
                out = []
                t = threading.Thread(target=lambda: out.append(_idj_host.get_key())); t.start(); t.join()
                return [a] + out
            def key(self): return _idj_host.get_key()
        """, key: "pool")
        let r = try await call(key, "run")
        XCTAssertTrue(r.hasPrefix(#"[[0, "pool", "w_0"], [1, "pool", "w_"#), r)
        XCTAssertEqual(Set(host.calls.filter { $0.name == "echo" }.map(\.key)), ["pool"])
        let k = try await call(key, "keys")
        XCTAssertEqual(k, #"["other", "other"]"#)
        let back = try await call(key, "key")   // set_key lasts until the call returns
        XCTAssertEqual(back, #""pool""#)
    }

    func testHostFailureIsAnException() async throws {
        let key = try await load("""
        import _idj_host
        class Spider:
            def bad(self):
                out = []
                for args in (('x',), (1, '{}'), ('a\\0b', '{}')):
                    try: _idj_host.call(*args)
                    except Exception as e: out.append(type(e).__name__)
                out.append(len(_idj_host.call('echo', '"\\ud800"')) > 0)
                return out
        """)
        let r = try await call(key, "bad")
        XCTAssertEqual(r, #"["TypeError", "TypeError", "ValueError", true]"#)
    }

    func testPrintGoesToTheHostLog() async throws {
        let key = try await load("""
        import sys
        class Spider:
            def run(self):
                print('第一行', 1)
                print('a\\nb')
                sys.stderr.write('无换行')
                sys.stdout.buffer.write('字节\\n'.encode())
                sys.stdout.flush()
        """, key: "printer")
        let r = try await call(key, "run")
        XCTAssertEqual(r, "null")
        XCTAssertEqual(host.logs("printer"), ["第一行 1", "a", "b", "字节", "无换行"])
    }

    // MARK: Concurrency

    func testSpidersDoNotBlockEachOther() async throws {
        let source = """
        import _idj_host, time
        class Spider:
            def slow(self): _idj_host.call('sleep', '{"s": 1.5}'); return 'slow'
            def fast(self): return sum(range(1000))
            def nap(self): time.sleep(1.5); return 'nap'
        """
        let a = try await load(source), b = try await load(source), c = try await load(source)
        let start = Date()
        async let slow = call(a, "slow")
        async let nap = call(b, "nap")
        try await Task.sleep(nanoseconds: 200_000_000)
        let t0 = Date()
        for _ in 0..<5 {
            let r = try await call(c, "fast")
            XCTAssertEqual(r, "499500")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        let results = try await [slow, nap]
        XCTAssertEqual(results, [#""slow""#, #""nap""#])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.8)
    }

    func testCallsToOneSpiderAreSerialOnOneThread() async throws {
        let key = try await load("""
        import threading, time
        class Spider:
            active = 0
            peak = 0
            def __init__(self): self.local = threading.local(); self.threads = set()
            def run(self, i):
                self.active += 1; self.peak = max(self.peak, self.active)
                self.threads.add(threading.get_ident())
                self.local.n = getattr(self.local, 'n', 0) + 1
                time.sleep(0.02)
                self.active -= 1
                return i
            def stats(self): return [self.peak, len(self.threads), self.local.n]
        """)
        let sum = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 { group.addTask { Int(try await self.call(key, "run", [i])) ?? -1 } }
            return try await group.reduce(0, +)
        }
        XCTAssertEqual(sum, 45)
        let stats = try await call(key, "stats")
        XCTAssertEqual(stats, "[1, 1, 10]")
    }

    @MainActor
    func testMainThreadIsNeverBlocked() async throws {
        let key = try await load("""
        class Spider:
            def spin(self):
                n = 0
                while True: n += 1
        """)
        let ticks = Counter()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in ticks.n += 1 }
        let e = await error { _ = try await self.call(key, "spin", timeout: 1) }
        timer.invalidate()
        XCTAssertEqual(e as? PythonError, .timeout)
        XCTAssertGreaterThan(ticks.n, 20)
    }

    // MARK: Errors, time limits

    func testExceptionText() async throws {
        let key = try await load("""
        class Spider:
            def boom(self):
                raise ValueError('坏了\\n第二行')
            def exit(self):
                import sys; sys.exit('bye')
            def missing(self):
                import no_such_module
            def deep(self):
                return self.deep()
            def json_deep(self):
                import json
                json.loads('[' * 200000)
            def parse_deep(self):
                eval('(' * 5000 + ')' * 5000)
            def repr_deep(self):
                x = []
                for _ in range(200000): x = [x]
                repr(x)
            def ok(self): return 'ok'
        """, key: "errors")
        let expected = ["boom": "ValueError: 坏了 第二行", "exit": "SystemExit: bye", "missing": "ModuleNotFoundError: No module named 'no_such_module'",
                        "nope": "AttributeError: 'Spider' object has no attribute 'nope'"]
        for (method, text) in expected {
            let e = await error { _ = try await self.call(key, method) }
            XCTAssertEqual(e as? PythonError, .script(text))
            XCTAssertEqual(e?.localizedDescription, text)
        }
        XCTAssertTrue(host.logs("errors").contains { $0.contains("Traceback (most recent call last)") && $0.contains("ValueError: 坏了\n第二行") && $0.contains("errors.py") })
        for method in ["deep", "json_deep", "parse_deep", "repr_deep"] {
            let e = await error { _ = try await self.call(key, method) }
            XCTAssertNotNil(e as? PythonError, method)
        }
        let r = try await call(key, "ok")
        XCTAssertEqual(r, #""ok""#)
    }

    func testLoadErrors() async throws {
        var e = await error { try await self.load("def broken(:\n  pass", key: "syntax") }
        XCTAssertTrue(e?.localizedDescription.hasPrefix("SyntaxError: ") == true, e?.localizedDescription ?? "nil")
        e = await error { _ = try await self.call("syntax", "x") }
        XCTAssertEqual(e as? PythonError, .notLoaded)
        e = await error { try await self.load("class Spider:\n    def init(self, ext): raise KeyError(ext)", key: "init", ext: "e") }
        XCTAssertEqual(e as? PythonError, .script("KeyError: 'e'"))
        e = await error { try await self.load("while True: pass", key: "loop", timeout: 0.5) }
        XCTAssertEqual(e as? PythonError, .timeout)
        e = await error { try await self.runtime.load(key: "x", source: "", ext: "", timeout: 5, runner: "idj_no_such_runner") }
        XCTAssertEqual(e as? PythonError, .script("缺少 Python 脚本库 idj_no_such_runner"))
        // The same key can be loaded again afterwards.
        try await load("class Spider:\n    def a(self): return 1", key: "loop")
        let r = try await call("loop", "a")
        XCTAssertEqual(r, "1")
    }

    func testTimeoutAndRecovery() async throws {
        let key = try await load("""
        class Spider:
            n = 0
            def spin(self):
                while True: self.n += 1
            def stubborn(self):
                import time
                end = time.time() + 2.5
                def hold(depth):
                    while time.time() < end:
                        try: hold(depth - 1) if depth else sum(range(1000))
                        except BaseException: pass
                hold(30)
            def blocked(self):
                import time; time.sleep(3)
            def mark(self): self.marked = True
            def state(self): return [self.n > 0, hasattr(self, 'marked')]
        """)
        _ = try await call(key, "mark")
        var t = Date()
        var e = await error { _ = try await self.call(key, "spin", timeout: 0.5) }
        XCTAssertEqual(e as? PythonError, .timeout)
        XCTAssertEqual(e?.localizedDescription, "Python 脚本执行超时")
        XCTAssertLessThan(Date().timeIntervalSince(t), 1.5)
        // The interrupt worked: same thread, same state.
        var r = try await call(key, "state")
        XCTAssertEqual(r, "[true, true]")

        // A script that swallows the interrupt, or sits in a blocking C call: new thread, script loaded again.
        for method in ["stubborn", "blocked"] {
            _ = try await call(key, "mark")
            t = Date()
            e = await error { _ = try await self.call(key, method, timeout: 0.3) }
            XCTAssertEqual(e as? PythonError, .timeout)
            r = try await call(key, "state")
            XCTAssertEqual(r, "[false, false]", method)
            XCTAssertLessThan(Date().timeIntervalSince(t), 2.4, method)
        }
        // Late interrupts do not hit later calls.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        for _ in 0..<20 {
            r = try await call(key, "state")
            XCTAssertEqual(r, "[false, false]")
        }
    }

    /// `re` never releases the GIL: the call still fails on time and the spider recovers once the match ends.
    func testTimeoutWhileTheGILIsHeld() async throws {
        let key = try await load("""
        import re
        class Spider:
            def match(self): return re.match(r'(a+)+$', 'a' * 26 + 'b') is None
            def ok(self): return 1
        """)
        let t = Date()
        let e = await error { _ = try await self.call(key, "match", timeout: 0.3) }
        XCTAssertEqual(e as? PythonError, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        let r = try await call(key, "ok", timeout: 60)
        XCTAssertEqual(r, "1")
    }

    func testTimeoutInterruptsThreadsOfTheScript() async throws {
        let key = try await load("""
        import threading, time, _idj_host
        from concurrent.futures import ThreadPoolExecutor
        class Spider:
            def run(self):
                def spin():
                    while True: time.sleep(0.01)
                with ThreadPoolExecutor(3) as ex: list(ex.map(lambda _: spin(), range(3)))
            def threads(self): return sum(t.name.startswith('ThreadPool') for t in threading.enumerate())
        """)
        let e = await error { _ = try await self.call(key, "run", timeout: 0.5) }
        XCTAssertEqual(e as? PythonError, .timeout)
        var n = ""
        for _ in 0..<40 where n != "0" {
            n = try await call(key, "threads")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(n, "0")
    }

    func testCancellation() async throws {
        let key = try await load("""
        import time
        class Spider:
            done = 0
            def slow(self): time.sleep(0.6); self.done += 1
            def count(self): return self.done
        """)
        let first = Task { try await self.call(key, "slow") }
        let queued = Task { try await self.call(key, "slow") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let t = Date()
        first.cancel(); queued.cancel()
        let e1 = await error { _ = try await first.value }, e2 = await error { _ = try await queued.value }
        XCTAssertTrue(e1 is CancellationError)
        XCTAssertTrue(e2 is CancellationError)
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.3)
        let n = try await call(key, "count")   // the running call finished, the queued one never started
        XCTAssertEqual(n, "1")
    }

    // MARK: Unload

    func testUnloadEndsTheThreadAndDestroysTheSpider() async throws {
        let before = PythonRuntime.liveThreads
        let key = try await load("""
        import _idj_host, threading, time
        class Spider:
            def start(self):
                def spin():
                    while True: time.sleep(0.01)
                threading.Thread(target=spin, name='leftover', daemon=True).start()
            def destroy(self): _idj_host.call('destroyed', '{}')
        """)
        _ = try await call(key, "start")
        runtime.unload(key: key)
        let e = await error { _ = try await self.call(key, "start") }
        XCTAssertEqual(e as? PythonError, .notLoaded)
        let ended = try await wait(5) { PythonRuntime.liveThreads <= before }
        XCTAssertTrue(ended, "\(PythonRuntime.liveThreads) > \(before)")
        XCTAssertEqual(host.calls.filter { $0.name == "destroyed" }.map(\.key), [key])
        try await Task.sleep(nanoseconds: 200_000_000)
        let left = try await eval("import threading\nreturn sum(t.name == 'leftover' for t in threading.enumerate())")
        XCTAssertEqual(left, "0")
    }

    func testUnloadAfterTheThreadWasGivenUp() async throws {
        let before = PythonRuntime.liveThreads
        let key = try await load("""
        import _idj_host, time
        class Spider:
            def blocked(self): time.sleep(2.5)
            def destroy(self): _idj_host.call('destroyed', '{}')
        """)
        _ = await error { _ = try await self.call(key, "blocked", timeout: 0.2) }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        runtime.unload(key: key)
        let destroyed = try await wait(1) { self.host.calls.contains { $0.name == "destroyed" } }
        XCTAssertTrue(destroyed)
        let ended = try await wait(5) { PythonRuntime.liveThreads <= before }
        XCTAssertTrue(ended, "\(PythonRuntime.liveThreads) > \(before)")
        XCTAssertEqual(host.calls.filter { $0.name == "destroyed" }.map(\.key), [key])
    }

    func testUnloadRacesARunningCall() async throws {
        let key = "race"
        let source = """
        import _idj_host
        class Spider:
            def spin(self):
                while True: pass
            def ok(self): return 'ok'
            def destroy(self): _idj_host.call('destroyed', '{}')
        """
        for _ in 0..<5 {
            try await load(source, key: key)
            let running = Task { try await self.call(key, "spin") }
            try await Task.sleep(nanoseconds: 50_000_000)
            let queued = Task { try await self.call(key, "ok") }
            try await Task.sleep(nanoseconds: 50_000_000)
            let t = Date()
            runtime.unload(key: key)
            for task in [running, queued] {
                let e = await error { _ = try await task.value } as? PythonError
                XCTAssertEqual(e, .unloaded)
            }
            XCTAssertLessThan(Date().timeIntervalSince(t), 1)
            // Loading again at once waits for the old thread, so its unload does not remove the new spider.
            try await load(source, key: key)
            let r = try await call(key, "ok")
            XCTAssertEqual(r, #""ok""#)
            runtime.unload(key: key)
        }
        let ended = try await wait(5) { self.host.calls.filter { $0.name == "destroyed" }.count == 10 }
        XCTAssertTrue(ended, "\(host.calls.filter { $0.name == "destroyed" }.count)")
    }

    func testManySpidersLeaveNothingBehind() async throws {
        let before = PythonRuntime.liveThreads
        let objects = "import gc\nreturn sum(type(o).__name__ == 'Spider' for o in gc.get_objects())"
        for round in 0..<3 {
            let all = (0..<12).map { "many-\(round)-\($0)" }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for k in all {
                    group.addTask {
                        try await self.runtime.load(key: k, source: "class Spider:\n    def __init__(self): self.me = self; self.big = bytearray(1 << 20)\n    def v(self): return 1", ext: "", timeout: 20, runner: Self.runner)
                        _ = try await self.runtime.call(key: k, method: "v", argsJSON: "[]", timeout: 20)
                    }
                }
                try await group.waitForAll()
            }
            for k in all { runtime.unload(key: k) }
        }
        let ended = try await wait(10) { PythonRuntime.liveThreads <= before }
        XCTAssertTrue(ended, "\(PythonRuntime.liveThreads) > \(before)")
        let left = try await eval("import gc; gc.collect()\n" + objects)
        XCTAssertLessThanOrEqual(Int(left) ?? 99, 2)   // this one and at most one that is just ending
    }

    func testReplacingAScript() async throws {
        let key = try await load("class Spider:\n    def v(self): return 1", key: "replace")
        try await load("class Spider:\n    def v(self): return 2", key: key)
        let r = try await call(key, "v")
        XCTAssertEqual(r, "2")
    }

    /// The production runner and libraries, once shared/tvbox/py has them.
    func testProductionRunnerLoads() async throws {
        guard FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/tvbox/py/idj_runner.py") else { throw XCTSkip("shared/tvbox/py/idj_runner.py is not there yet") }
        let r = try await eval("import idj_runner\nreturn [callable(getattr(idj_runner, n)) for n in ('load', 'call', 'unload')]")
        XCTAssertEqual(r, "[true, true, true]")
    }
}

private final class Counter: @unchecked Sendable { var n = 0 }

/// A host that records calls. `echo` returns its arguments, `sleep` blocks for `s` seconds.
private final class RecordingHost: @unchecked Sendable {
    struct Call { let key: String, name: String, args: String, onMainThread: Bool }
    private let lock = NSLock()
    private var list: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return list }

    func logs(_ key: String) -> [String] {
        calls.filter { $0.name == "log" && $0.key == key }.compactMap {
            ((try? JSONSerialization.jsonObject(with: Data($0.args.utf8))) as? [String: Any])?["m"] as? String
        }
    }

    func call(_ key: String, _ name: String, _ args: String) -> String {
        lock.lock()
        list.append(Call(key: key, name: name, args: args, onMainThread: Thread.isMainThread))
        lock.unlock()
        switch name {
        case "echo": return #"{"v":"# + args + "}"
        case "sleep":
            let o = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
            Thread.sleep(forTimeInterval: o?["s"] as? Double ?? 0)
            return #"{"v":null}"#
        default: return #"{"v":null}"#
        }
    }
}
