import Foundation
import WebKit

/// Cookie 原语的防重入写保护接口。
///
/// 原语在写/删 WK store 前后调用 begin/endInternalWrite;
/// 由 CookieStoreObserverHandler 实现——internalWriteCount > 0 时
/// observer 忽略 cookiesDidChange,避免自家写入触发 sweep 死循环。
protocol CookieWriteGuard: AnyObject {
  func beginInternalWrite()
  func endInternalWrite()
}

/// iOS / macOS 共享的 cookie 引擎原语(自 AppDelegate / MainFlutterWindow 提取)。
///
/// 设计依据: docs/cookie-sync-design-v0.4.0.md §5.4
///
/// 关键平台特性 (依据 §3.1 / §3.2 / §3.6):
/// - WKHTTPCookieStore 与 HTTPCookieStorage.shared 同步不可靠 → 双写双删
/// - WKHTTPCookieStore.delete completion 在 main queue 回调
/// - HTTPCookie.domain 对 host-only cookie 仍返回 host (无前导点)
///
/// store / storage 均由调用方注入:生产传 WKWebsiteDataStore.default().httpCookieStore
/// 与 HTTPCookieStorage.shared;单测传 nonPersistent store 与独立 storage,
/// 保证可测且不污染真实数据。
enum CookiePrimitives {

  /// 把 HTTPCookie.sameSitePolicy 转成 Dart 端可识别的字符串 ("Lax"/"Strict"/"None")。
  /// iOS 13+/macOS 10.15+ 支持; 早期系统返回 nil。
  static func sameSiteString(_ cookie: HTTPCookie) -> String? {
    if #available(iOS 13.0, macOS 10.15, *) {
      guard let policy = cookie.sameSitePolicy else { return nil }
      switch policy {
      case .sameSiteLax:
        return "Lax"
      case .sameSiteStrict:
        return "Strict"
      default:
        let raw = policy.rawValue.lowercased()
        if raw.contains("none") { return "None" }
        if raw.contains("lax") { return "Lax" }
        if raw.contains("strict") { return "Strict" }
        return nil
      }
    }
    return nil
  }

  /// domain 匹配规则 (用于 Sentinel 枚举/删除变体)
  ///
  /// - candidate 为 nil 表示 host-only 候选, 要求 cookie.domain == host
  /// - candidate 非 nil 时, 容忍前导点差异 (".example.com" 等价 "example.com")
  static func matchDomain(cookieDomain: String, candidate: String?, host: String) -> Bool {
    let normalizedCookieDomain = (cookieDomain.hasPrefix(".")
      ? String(cookieDomain.dropFirst())
      : cookieDomain).lowercased()
    if let candidate = candidate {
      let normalizedCandidate = (candidate.hasPrefix(".")
        ? String(candidate.dropFirst())
        : candidate).lowercased()
      return normalizedCookieDomain == normalizedCandidate
    } else {
      return normalizedCookieDomain == host
    }
  }

  /// host 是否落在 cookie domain 的适用范围(等于该域或为其子域)
  static func domainApplies(cookieDomain: String, host: String) -> Bool {
    let normalized = (cookieDomain.hasPrefix(".")
      ? String(cookieDomain.dropFirst())
      : cookieDomain).lowercased()
    return host == normalized || host.hasSuffix("." + normalized)
  }

  /// 从注入 storage 中删除与 cookie 同 (name, path, domain 语义) 的条目
  static func deleteSharedCookie(
    storage: HTTPCookieStorage,
    url: URL,
    cookie: HTTPCookie
  ) {
    let host = (url.host ?? "").lowercased()
    guard let sharedCookies = storage.cookies else { return }
    for sharedCookie in sharedCookies where
      sharedCookie.name == cookie.name &&
      sharedCookie.path == cookie.path &&
      matchDomain(cookieDomain: sharedCookie.domain, candidate: cookie.domain, host: host) {
      storage.deleteCookie(sharedCookie)
    }
  }

  /// 暴力穷举删除指定 name 的所有变体 (WK store + 注入 storage 双删)
  ///
  /// 枚举真实 cookie 对象,按 name + 适用域过滤(与 countCookiesByName 对齐),
  /// 逐个 store.delete 真实对象,杜绝 "count 数得到、nuke 删不掉" 的残留循环。
  /// completion 回 WK store 侧实际删除条数(main queue)。
  static func nukeAllVariants(
    store: WKHTTPCookieStore,
    storage: HTTPCookieStorage,
    url: URL,
    name: String,
    writeGuard: CookieWriteGuard?,
    completion: @escaping (Int) -> Void
  ) {
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let matching = cookies.filter { cookie in
        cookie.name == name && domainApplies(cookieDomain: cookie.domain, host: host)
      }

      writeGuard?.beginInternalWrite()
      let group = DispatchGroup()
      let countLock = NSLock()
      var deletedCount = 0

      for cookie in matching {
        group.enter()
        store.delete(cookie) {
          countLock.lock()
          deletedCount += 1
          countLock.unlock()
          group.leave()
        }
      }

      // 双删: 同步清注入 storage 中匹配的同名 cookie
      if let sharedCookies = storage.cookies {
        for cookie in sharedCookies where cookie.name == name {
          if domainApplies(cookieDomain: cookie.domain, host: host) {
            storage.deleteCookie(cookie)
          }
        }
      }

      group.notify(queue: .main) {
        writeGuard?.endInternalWrite()
        completion(deletedCount)
      }
    }
  }

  /// 精确删除指定 (name, domain, path) 的单条 cookie 变体
  static func deleteExactCookie(
    store: WKHTTPCookieStore,
    storage: HTTPCookieStorage,
    url: URL,
    name: String,
    domain: String?,
    path: String,
    writeGuard: CookieWriteGuard?,
    completion: @escaping (Bool) -> Void
  ) {
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let target = cookies.first { cookie in
        cookie.name == name &&
        cookie.path == path &&
        matchDomain(cookieDomain: cookie.domain, candidate: domain, host: host)
      }
      guard let cookie = target else {
        DispatchQueue.main.async { completion(false) }
        return
      }

      writeGuard?.beginInternalWrite()
      let group = DispatchGroup()
      group.enter()
      store.delete(cookie) {
        group.leave()
      }

      // 双删: 同步清注入 storage 中匹配的同名 cookie
      if let sharedCookies = storage.cookies {
        for sharedCookie in sharedCookies where
          sharedCookie.name == name &&
          sharedCookie.path == path &&
          matchDomain(cookieDomain: sharedCookie.domain, candidate: domain, host: host) {
          storage.deleteCookie(sharedCookie)
        }
      }

      group.notify(queue: .main) {
        writeGuard?.endInternalWrite()
        completion(true)
      }
    }
  }

  /// 读取指定 url 下所有适用 cookie 的完整信息
  ///
  /// 适用判断: cookie.domain (去前导点) == host, 或 host 是其子域
  static func getAllCookieInfos(
    store: WKHTTPCookieStore,
    url: URL,
    completion: @escaping ([[String: Any?]]) -> Void
  ) {
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let applicable = cookies.filter { cookie in
        domainApplies(cookieDomain: cookie.domain, host: host)
      }

      let infos: [[String: Any?]] = applicable.map { cookie in
        return [
          "name": cookie.name,
          "value": cookie.value,
          "domain": cookie.domain,
          "path": cookie.path,
          "isSecure": cookie.isSecure,
          "isHttpOnly": cookie.isHTTPOnly,
          "expiresMillis": cookie.expiresDate.map { Int($0.timeIntervalSince1970 * 1000) },
          "sameSite": sameSiteString(cookie),
        ]
      }

      DispatchQueue.main.async {
        completion(infos)
      }
    }
  }

  /// 统计指定 url 下 cookie name 的变体数 (适用域过滤)
  static func countCookiesByName(
    store: WKHTTPCookieStore,
    url: URL,
    name: String,
    completion: @escaping (Int) -> Void
  ) {
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let count = cookies.filter { cookie in
        cookie.name == name && domainApplies(cookieDomain: cookie.domain, host: host)
      }.count

      DispatchQueue.main.async {
        completion(count)
      }
    }
  }
}
