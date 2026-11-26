import SwiftUI

extension View {
    /// Screenshot hook (DEBUG only): `STV_TVBOX_SHOW=<state>` brings a surface up by itself once the fixture is in place.
    /// `states`: comma separated; `id`: what the action works on (a new pane asks again).
    @ViewBuilder func tvboxShot(_ states: String, id: AnyHashable = 0, after seconds: Double = 2, file: String = #fileID, _ action: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        task(id: id) {
            guard TVBoxFixture.asks(states) else { return }
            await TVBoxFixture.settled()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, TVBoxFixture.claim(states, file) else { return }
            action()
        }
        #else
        self
        #endif
    }
}

#if DEBUG
/// UI-test / screenshot hook (DEBUG only): `STV_TVBOX_FIXTURE=1` replaces the configs with a local one. Its sites run the
/// script engine on a local script, its live list and guide are local too, so the whole page works offline.
/// `STV_TVBOX_TRUST=0` leaves the trust question open.
@MainActor
enum TVBoxFixture {
    private static var done = false
    private static var finished = false
    private static var shown = Set<String>()

    static func asks(_ states: String) -> Bool {
        guard let want = ProcessInfo.processInfo.environment["STV_TVBOX_SHOW"] else { return false }
        return states.components(separatedBy: ",").contains(want)
    }

    /// Once per place.
    static func claim(_ states: String, _ place: String) -> Bool { shown.insert(place + "|" + states).inserted }

    /// Returns when the fixture has replaced the configs (at once without one).
    static func settled() async {
        while !finished, ProcessInfo.processInfo.environment["STV_TVBOX_FIXTURE"] == "1" {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
    }

    static func seedIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["STV_TVBOX_FIXTURE"] == "1", !done else { return }
        done = true
        defer { finished = true }
        let store = TVBoxStore.shared
        await store.ready()
        for r in store.repos { store.remove(r.id) }
        for d in store.state.depots { store.removeDepot(d.id) }
        do {
            _ = try await store.importLocal(Data(script.utf8), fileName: "fixture.js")
            _ = try await store.importLocal(Data(guide().utf8), fileName: "guide.js")
            _ = try await store.importLocal(Data(second.utf8), fileName: "second.json", name: "备用配置")
            guard case .imported(let r) = try await store.importLocal(Data(config.utf8), fileName: "demo.json", name: "示例配置") else { return }
            if env["STV_TVBOX_TRUST"] != "0" { store.setTrust(r.id, .trusted) }
            for (i, s) in r.sites.prefix(1).enumerated() {
                for n in 1...3 {
                    let series = HGSeries(source: .tvbox(s.uid), seriesId: "movie-\(n)", title: "示例影片 \(n)", cover: "fixture://\(colors[n + i])/p", episodeCount: 12, orientation: "portrait")
                    LibraryStore.shared.record(series, index: n, ep: n + 1, seconds: Double(300 * n), duration: 1500)
                }
            }
        } catch { NSLog("%@", "[TVBoxFixture] \(error.localizedDescription)") }
    }

    private static let colors = ["3A6EA5", "C0504D", "6A994E", "8064A2", "4BACC6", "F79646", "2C4D75", "BC4749", "81B29A", "98C1D9"]

    private static let config = """
    {"name":"示例配置","notice":"离线示例数据，仅用于界面检查。","spider":"https://demo.example.com/spider.jar",
     "sites":[
      {"key":"movie","name":"示例影视","type":3,"api":"clan://localhost/fixture.js","ext":"movie"},
      {"key":"clip","name":"示例短片（横图）","type":3,"api":"clan://localhost/fixture.js","ext":"clip"},
      {"key":"cms","name":"示例采集站","type":1,"api":"https://cms.demo.example.invalid/api.php/provide/vod/"},
      {"key":"t4","name":"远程站点","type":4,"api":"https://t4.demo.example.invalid/api","searchable":0},
      {"key":"jar","name":"JAR 站点","type":3,"api":"csp_Demo"},
      {"key":"py","name":"Python 站点","type":3,"api":"https://demo.example.invalid/a.py"},
      {"key":"odd","name":"未知站点","type":9,"api":"odd"}],
     "parses":[{"name":"示例解析","type":1,"url":"https://parse.demo.example.invalid/?url="},{"name":"网页解析","type":0,"url":"https://web.demo.example.invalid/?url="}],
     "lives":[{"name":"示例直播","epg":"clan://localhost/guide.js","groups":[
       {"name":"央视","channel":[\(channels(["CCTV-1 综合", "CCTV-2 财经", "CCTV-5 体育", "CCTV-13 新闻"], logo: true))]},
       {"name":"卫视","channel":[\(channels(["湖南卫视", "浙江卫视", "东方卫视", "北京卫视", "江苏卫视"], logo: false))]},
       {"name":"私密分组","pass":"1234","channel":[\(channels(["私密频道一", "私密频道二"], logo: false))]}]},
      {"name":"备用直播","url":"https://live.demo.example.invalid/a.m3u"}]}
    """

    private static let second = """
    {"name":"备用配置","sites":[{"key":"a","name":"备用采集站","type":1,"api":"https://a.demo.example.invalid/api.php/provide/vod/"}],"lives":[]}
    """

    private static func channels(_ names: [String], logo: Bool) -> String {
        var out: [String] = []
        for (i, n) in names.enumerated() {
            let picture = logo ? "fixture://" + colors[i % colors.count] : ""
            let urls = "[\"https://live.demo.example.invalid/\(i).m3u8\",\"https://live2.demo.example.invalid/\(i).m3u8\"]"
            out.append("{\"name\":\"\(n)\",\"urls\":\(urls),\"logo\":\"\(picture)\"}")
        }
        return out.joined(separator: ",")
    }

    /// XMLTV around now.
    private static func guide() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss Z"
        let start = Date().addingTimeInterval(-1800)
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><tv>"
        for n in ["CCTV-1 综合", "CCTV-5 体育", "湖南卫视", "东方卫视"] {
            out += "<channel id=\"\(n)\"><display-name>\(n)</display-name></channel>"
            for (i, t) in ["示例晚间节目", "示例纪录片"].enumerated() {
                let a = start.addingTimeInterval(Double(i) * 3600), b = a.addingTimeInterval(3600)
                out += "<programme start=\"\(f.string(from: a))\" stop=\"\(f.string(from: b))\" channel=\"\(n)\"><title>\(t)</title></programme>"
            }
        }
        return out + "</tv>"
    }

    private static let script = """
    var wide = false;
    var colors = ["3A6EA5", "C0504D", "6A994E", "8064A2", "4BACC6", "F79646", "2C4D75", "BC4749", "81B29A", "98C1D9"];
    var names = ["山海之间", "城市夜跑", "雾中灯塔", "海边小镇", "星河旅人", "春日来信", "北方以北", "风起时", "长街", "归途", "晴天日记", "白鸟"];
    function card(i, prefix) {
      var c = { vod_id: prefix + i, vod_name: names[i % names.length] + (i >= names.length ? " " + (Math.floor(i / names.length) + 1) : ""),
                vod_pic: "fixture://" + colors[i % colors.length] + (wide ? "" : "/p"), vod_remarks: i % 3 ? "更新至" + (i + 8) + "集" : "HD" };
      if (wide) c.style = { type: "rect", ratio: 1.78 };
      return c;
    }
    function many(from, n, prefix) { var out = []; for (var i = 0; i < n; i++) out.push(card(from + i, prefix)); return out; }
    function options(list) { return list.map(function (n, i) { return { n: n, v: i ? n : "" }; }); }
    export default {
      init: function (ext) { wide = ext === "clip"; },
      home: function () {
        var cls = ["电影", "连续剧", "综艺", "动漫", "纪录片", "文件夹"].map(function (n, i) { return { type_id: String(i + 1), type_name: n }; });
        var f = [{ key: "area", name: "地区", value: options(["全部", "大陆", "香港", "台湾", "美国", "日本", "韩国", "英国", "法国"]) },
                 { key: "year", name: "年份", value: options(["全部", "2026", "2025", "2024", "2023", "2022", "更早"]) }];
        return JSON.stringify({ "class": cls, filters: { "1": f } });
      },
      homeVod: function () { return JSON.stringify({ list: many(0, 12, "movie-") }); },
      category: function (tid, pg) {
        if (tid === "6") {
          var dirs = ["我的收藏夹", "示例目录"].map(function (n, i) { return { vod_id: "dir-" + i, vod_name: n, vod_tag: "folder", vod_remarks: "目录" }; });
          dirs.push({ vod_id: "run", vod_name: "清理缓存", vod_pic: "fixture://81B29A/p", vod_remarks: "操作", action: "clean" });
          return JSON.stringify({ list: dirs, pagecount: 1 });
        }
        if (tid.indexOf("dir-") === 0) return JSON.stringify({ list: many(0, 6, tid + "-"), pagecount: 1 });
        if (tid === "5") throw new Error("示例错误：分类暂时打不开");
        return JSON.stringify({ list: many((Number(pg) - 1) * 18, 18, "c" + tid + "-"), page: Number(pg), pagecount: 4 });
      },
      detail: function (id) {
        return JSON.stringify({ list: [{ vod_id: id, vod_name: "示例影片", vod_pic: "fixture://3A6EA5/p", vod_content: "离线示例。", vod_play_from: "线路一$$$线路二",
          vod_play_url: "第1集$https://v.demo.example.invalid/1.m3u8#第2集$https://v.demo.example.invalid/2.m3u8$$$第1集$https://w.demo.example.invalid/1.m3u8" }] });
      },
      search: function (wd) { return JSON.stringify({ list: many(0, wide ? 4 : 9, "s-") }); },
      play: function (flag, id) { return JSON.stringify({ parse: 0, url: id }); },
      action: function (a) { return JSON.stringify({ msg: "示例操作已完成" }); }
    };
    """
}
#endif
