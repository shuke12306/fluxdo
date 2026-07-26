import WebKit
import XCTest

@testable import Runner

/// CookiePrimitives 单测。
///
/// 纯逻辑部分(matchDomain/domainApplies/sameSiteString)直接断言;
/// 集成部分用 nonPersistent WKWebsiteDataStore + group 隔离的
/// HTTPCookieStorage,在真实 WK cookie store 上验证 nuke/deleteExact/
/// count/getAll 的行为与双删语义,不污染 App 数据。
final class CookiePrimitivesTests: XCTestCase {

  /// nonPersistent dataStore 必须强持有,否则 httpCookieStore 随时失效
  private var dataStore: WKWebsiteDataStore!
  private var store: WKHTTPCookieStore!
  private var storage: HTTPCookieStorage!

  private let url = URL(string: "https://linux.do/latest")!

  override func setUp() {
    super.setUp()
    dataStore = WKWebsiteDataStore.nonPersistent()
    store = dataStore.httpCookieStore
    storage = HTTPCookieStorage.sharedCookieStorage(
      forGroupContainerIdentifier: "CookiePrimitivesTests"
    )
    if let cookies = storage.cookies {
      for cookie in cookies { storage.deleteCookie(cookie) }
    }
  }

  override func tearDown() {
    dataStore = nil
    store = nil
    storage = nil
    super.tearDown()
  }

  // MARK: - 工具

  private func makeCookie(
    name: String,
    value: String = "v",
    domain: String = "linux.do",
    path: String = "/",
    origin: String = "https://linux.do"
  ) -> HTTPCookie {
    return HTTPCookie(properties: [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
      .originURL: origin,
    ])!
  }

  private func cookieFromHeader(_ setCookie: String) -> HTTPCookie? {
    return HTTPCookie.cookies(
      withResponseHeaderFields: ["Set-Cookie": setCookie],
      for: URL(string: "https://linux.do")!
    ).first
  }

  /// 往 WK store 依序写入 cookie(WKHTTPCookieStore 无批量接口)
  private func seed(_ cookies: [HTTPCookie]) {
    for cookie in cookies {
      let exp = expectation(description: "seed \(cookie.name) \(cookie.domain) \(cookie.path)")
      store.setCookie(cookie) { exp.fulfill() }
      wait(for: [exp], timeout: 10)
    }
  }

  private final class WriteGuardSpy: CookieWriteGuard {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    func beginInternalWrite() { beginCount += 1 }
    func endInternalWrite() { endCount += 1 }
  }

  // MARK: - 纯逻辑: matchDomain / domainApplies / sameSiteString

  func testMatchDomainHostOnlyRequiresExactHost() {
    XCTAssertTrue(
      CookiePrimitives.matchDomain(cookieDomain: "linux.do", candidate: nil, host: "linux.do"))
    XCTAssertFalse(
      CookiePrimitives.matchDomain(cookieDomain: "linux.do", candidate: nil, host: "sub.linux.do"))
    XCTAssertFalse(
      CookiePrimitives.matchDomain(cookieDomain: "sub.linux.do", candidate: nil, host: "linux.do"))
  }

  func testMatchDomainToleratesLeadingDot() {
    XCTAssertTrue(
      CookiePrimitives.matchDomain(cookieDomain: ".linux.do", candidate: "linux.do", host: "linux.do"))
    XCTAssertTrue(
      CookiePrimitives.matchDomain(cookieDomain: "linux.do", candidate: ".linux.do", host: "linux.do"))
    XCTAssertFalse(
      CookiePrimitives.matchDomain(cookieDomain: ".linux.do", candidate: "example.com", host: "linux.do"))
  }

  func testMatchDomainIsCaseInsensitive() {
    XCTAssertTrue(
      CookiePrimitives.matchDomain(cookieDomain: ".Linux.DO", candidate: "linux.do", host: "linux.do"))
  }

  func testDomainAppliesCoversHostAndSubdomains() {
    XCTAssertTrue(CookiePrimitives.domainApplies(cookieDomain: ".linux.do", host: "linux.do"))
    XCTAssertTrue(CookiePrimitives.domainApplies(cookieDomain: "linux.do", host: "cdn.linux.do"))
    // 后缀攻击域: evil-linux.do 不是 linux.do 的子域
    XCTAssertFalse(CookiePrimitives.domainApplies(cookieDomain: "linux.do", host: "evil-linux.do"))
    XCTAssertFalse(CookiePrimitives.domainApplies(cookieDomain: "cdn.linux.do", host: "linux.do"))
  }

  func testSameSiteStringMapping() {
    // 走 Set-Cookie 头解析构造, 与线上 raw_cookie 通道同源
    let lax = cookieFromHeader("s=1; Path=/; SameSite=Lax")
    XCTAssertEqual(lax.flatMap { CookiePrimitives.sameSiteString($0) }, "Lax")

    let strict = cookieFromHeader("s=1; Path=/; SameSite=Strict")
    XCTAssertEqual(strict.flatMap { CookiePrimitives.sameSiteString($0) }, "Strict")

    let plain = cookieFromHeader("s=1; Path=/")
    XCTAssertNotNil(plain)
    XCTAssertNil(plain.flatMap { CookiePrimitives.sameSiteString($0) })
  }

  // MARK: - 集成: 真实 WKHTTPCookieStore

  func testNukeAllVariantsDeletesAllAndSparesOthers() {
    seed([
      makeCookie(name: "_t", domain: "linux.do", path: "/"),
      makeCookie(name: "_t", domain: ".linux.do", path: "/t"),
      makeCookie(name: "other", domain: "linux.do", path: "/"),
    ])
    // 注入 storage 侧也放一条同名 cookie, 验证双删
    storage.setCookie(makeCookie(name: "_t", domain: "linux.do", path: "/"))

    let guardSpy = WriteGuardSpy()
    let nukeExp = expectation(description: "nuke")
    var deleted = -1
    CookiePrimitives.nukeAllVariants(
      store: store, storage: storage, url: url, name: "_t", writeGuard: guardSpy
    ) { count in
      deleted = count
      nukeExp.fulfill()
    }
    wait(for: [nukeExp], timeout: 10)

    XCTAssertEqual(deleted, 2, "WK store 中 _t 的两个变体应全部删除")
    XCTAssertEqual(guardSpy.beginCount, 1)
    XCTAssertEqual(guardSpy.endCount, 1)
    XCTAssertEqual(
      storage.cookies?.filter { $0.name == "_t" }.count, 0,
      "注入 storage 侧的同名 cookie 应被双删")

    let countExp = expectation(description: "count after nuke")
    CookiePrimitives.countCookiesByName(store: store, url: url, name: "_t") { count in
      XCTAssertEqual(count, 0, "nuke 后不应有 _t 残留 (杜绝 count 数得到、nuke 删不掉)")
      countExp.fulfill()
    }
    wait(for: [countExp], timeout: 10)

    let infosExp = expectation(description: "others survive")
    CookiePrimitives.getAllCookieInfos(store: store, url: url) { infos in
      XCTAssertEqual(infos.count, 1)
      XCTAssertEqual(infos.first?["name"] as? String, "other")
      infosExp.fulfill()
    }
    wait(for: [infosExp], timeout: 10)
  }

  func testDeleteExactCookieRemovesOnlyTargetVariant() {
    seed([
      makeCookie(name: "_t", domain: "linux.do", path: "/"),
      makeCookie(name: "_t", domain: "linux.do", path: "/topic"),
    ])

    let delExp = expectation(description: "delete exact")
    CookiePrimitives.deleteExactCookie(
      store: store, storage: storage, url: url,
      name: "_t", domain: "linux.do", path: "/topic", writeGuard: nil
    ) { ok in
      XCTAssertTrue(ok)
      delExp.fulfill()
    }
    wait(for: [delExp], timeout: 10)

    let countExp = expectation(description: "one variant left")
    CookiePrimitives.countCookiesByName(store: store, url: url, name: "_t") { count in
      XCTAssertEqual(count, 1, "只应删除 path=/topic 的变体")
      countExp.fulfill()
    }
    wait(for: [countExp], timeout: 10)
  }

  func testDeleteExactCookieReturnsFalseWhenMissing() {
    let exp = expectation(description: "missing cookie")
    CookiePrimitives.deleteExactCookie(
      store: store, storage: storage, url: url,
      name: "nope", domain: nil, path: "/", writeGuard: nil
    ) { ok in
      XCTAssertFalse(ok)
      exp.fulfill()
    }
    wait(for: [exp], timeout: 10)
  }

  func testGetAllCookieInfosFiltersByApplicableDomain() {
    seed([
      makeCookie(name: "mine", domain: "linux.do"),
      makeCookie(name: "foreign", domain: "example.com", origin: "https://example.com"),
    ])

    let exp = expectation(description: "infos filtered")
    CookiePrimitives.getAllCookieInfos(store: store, url: url) { infos in
      XCTAssertEqual(infos.map { $0["name"] as? String }, ["mine"])
      exp.fulfill()
    }
    wait(for: [exp], timeout: 10)
  }
}
