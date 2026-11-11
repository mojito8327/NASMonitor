#!/bin/bash
# NASMonitor 版本号单一来源与发布门禁
#
# 唯一版本源 = 仓库根目录 VERSION（MARKETING / BUILD 两行）。
# 本脚本负责把版本「推」到所有会产生真实后果的地方：
#   Sources/NASMonitor/Version.swift   编译期常量（关于页 / --version / 自检）
#   Resources/Info.plist               CFBundleShortVersionString / CFBundleVersion
#   NASMonitor.app/Contents/Info.plist 组装后的包内 plist
#   dist/ 包名、SHA256SUMS、.gitignore 白名单、README 下载链接与 Release tag
#
# 用法：
#   ./scripts/version.sh print              打印当前版本与派生名称
#   ./scripts/version.sh sync              由 VERSION 重新生成 Version.swift + 回填 Info.plist 模板
#   ./scripts/version.sh stamp <plist>     把版本写进任意一份 plist（build.sh 用）
#   ./scripts/version.sh bump 1.2 [构建号] 推进版本并批量改文档引用（发布入口）
#   ./scripts/version.sh check [--skip-dist] 全量一致性门禁，不一致 exit 1
#
# 约定：每次功能更新 / 重新打包发布前，先跑 bump，再跑 build.sh，最后跑 check。
#       历史工作日志、设计档案里的旧校验值属于时点快照，故意不改写，也不参与门禁。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
SWIFT_FILE="$ROOT/Sources/NASMonitor/Version.swift"
TEMPLATE_PLIST="$ROOT/Resources/Info.plist"
BUNDLE_PLIST="$ROOT/NASMonitor.app/Contents/Info.plist"
PB="/usr/libexec/PlistBuddy"

NM_VERSION=""
NM_BUILD=""
NM_TAG=""
NM_ZIP=""

die()  { echo "✗ $*" >&2; exit 1; }

load() {
  [[ -f "$VERSION_FILE" ]] || die "缺少 $VERSION_FILE"
  MARKETING=""; BUILD=""
  # shellcheck disable=SC1090
  . "$VERSION_FILE"
  NM_VERSION="${MARKETING:-}"
  NM_BUILD="${BUILD:-}"
  [[ "$NM_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || die "VERSION 的 MARKETING 格式非法：'$NM_VERSION'（应为 1.1 或 1.1.1）"
  [[ "$NM_BUILD" =~ ^[0-9]+$ ]] \
    || die "VERSION 的 BUILD 格式非法：'$NM_BUILD'（应为正整数）"
  NM_TAG="v$NM_VERSION"
  NM_ZIP="NASMonitor-$NM_VERSION.zip"
}

# 比较 X.Y[.Z]，逐段按数值比（不是字典序）。$1 > $2 返回 0。
ver_gt() {
  local a="$1" b="$2" i av bv
  local -a A B
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  for i in 0 1 2; do
    av=$((10#${A[$i]:-0}))
    bv=$((10#${B[$i]:-0}))
    if (( av > bv )); then return 0; fi
    if (( av < bv )); then return 1; fi
  done
  return 1
}

# 只改两个版本值，保留原文件缩进与键顺序。
# 不用 PlistBuddy 写：它会把整个 plist 按字母重排 + 换成 tab 缩进，制造无意义的大 diff。
pb_set() {
  local p="$1" tmp
  [[ -f "$p" ]] || die "plist 不存在：$p"
  /usr/bin/grep -q '<key>CFBundleShortVersionString</key>' "$p" \
    || die "$p 缺少 CFBundleShortVersionString"
  /usr/bin/grep -q '<key>CFBundleVersion</key>' "$p" \
    || die "$p 缺少 CFBundleVersion"
  tmp="$(/usr/bin/mktemp "${p}.tmp.XXXXXX")" || die "无法创建临时 plist"
  if ! /usr/bin/awk -v sv="$NM_VERSION" -v bv="$NM_BUILD" '
      /<key>CFBundleShortVersionString<\/key>/ { print; getline;
          sub(/<string>[^<]*<\/string>/, "<string>" sv "</string>"); print; next }
      /<key>CFBundleVersion<\/key>/ { print; getline;
          sub(/<string>[^<]*<\/string>/, "<string>" bv "</string>"); print; next }
      { print }
    ' "$p" > "$tmp"; then
    /bin/rm -f "$tmp"; die "写入 plist 失败：$p"
  fi
  /bin/mv "$tmp" "$p"
}

pb_get() {
  "$PB" -c "Print :$1" "$2" 2>/dev/null || true
}

gen_swift() {
  mkdir -p "$(dirname "$SWIFT_FILE")"
  cat > "$SWIFT_FILE" <<SWIFT
import Foundation

// ⚠️ 本文件由 scripts/version.sh sync 从仓库根目录 VERSION 自动生成，请勿手改。
// 唯一版本源 = VERSION；改版本一律执行 ./scripts/version.sh bump <新版本>。
// 关于页、--version、发布门禁都读这里的常量，避免版本数字散落回源码。
enum AppVersion {
    static let marketing = "$NM_VERSION"
    static let build = "$NM_BUILD"
    static let tag = "$NM_TAG"
    static let zipName = "$NM_ZIP"

    static var display: String { "版本 \(marketing)" }
    static var full: String { "\(marketing) (\(build))" }

    /// 版本号格式：主版本.次版本[.修订]，每段必须是十进制整数，不接受前缀 / 后缀。
    static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.unicodeScalars.allSatisfy { ch in ch.value >= 48 && ch.value <= 57 }
        }
    }

    /// 按数值比较（补齐到 3 段），非法输入返回 nil。用于 bump 的单调递增校验。
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard isValid(a), isValid(b) else { return nil }
        let x = components(a), y = components(b)
        for i in 0..<3 {
            if x[i] != y[i] { return x[i] > y[i] ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func isValidBuild(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ch in ch.value >= 48 && ch.value <= 57 }
    }

    private static func components(_ s: String) -> [Int] {
        var v = s.split(separator: ".").map { piece in Int(piece) ?? 0 }
        while v.count < 3 { v.append(0) }
        return v
    }

    /// 运行时核对 .app 包内 plist 是否被旧包 / 手工改动污染。
    /// 命令行裸二进制（.build/release）没有 bundle，返回 .noBundle，属正常。
    enum BundleCheck: Equatable, CustomStringConvertible {
        case match
        case noBundle
        case mismatch(short: String?, build: String?)

        var description: String {
            switch self {
            case .match: return "一致"
            case .noBundle: return "命令行裸二进制（无 .app 包），跳过 plist 核对"
            case .mismatch(let s, let b):
                return "不一致：包内 \(s ?? "缺失") / \(b ?? "缺失")"
            }
        }
    }

    static func bundleCheck() -> BundleCheck {
        guard let info = Bundle.main.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String else {
            return .noBundle
        }
        let b = info["CFBundleVersion"] as? String
        return (short == marketing && b == build)
            ? .match : .mismatch(short: short, build: b)
    }
}

/// 纯内存自检：不建连接、不读 UserDefaults、不打开浏览器。
/// --version-selftest 会顺带核对当前进程的包内 plist（若在 .app 内运行）。
enum VersionSelfTest {
    static func run() {
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1; print("  ✗ \(label)") }
        }

        check("MARKETING 格式合法", AppVersion.isValid(AppVersion.marketing))
        check("BUILD 是十进制整数", AppVersion.isValidBuild(AppVersion.build))
        check("tag = v + MARKETING", AppVersion.tag == "v" + AppVersion.marketing)
        check("zipName 与版本一致",
              AppVersion.zipName == "NASMonitor-\(AppVersion.marketing).zip")
        check("display 不带硬编码数字", AppVersion.display == "版本 " + AppVersion.marketing)
        check("full 同时含版本与构建号",
              AppVersion.full.contains(AppVersion.marketing) && AppVersion.full.contains(AppVersion.build))

        check("isValid 1.1", AppVersion.isValid("1.1"))
        check("isValid 1.1.0", AppVersion.isValid("1.1.0"))
        check("isValid 10.25.3", AppVersion.isValid("10.25.3"))
        check("拒绝单段 1", !AppVersion.isValid("1"))
        check("拒绝四段 1.1.1.1", !AppVersion.isValid("1.1.1.1"))
        check("拒绝空段 1..1", !AppVersion.isValid("1..1"))
        check("拒绝带 v 前缀", !AppVersion.isValid("v1.1"))
        check("拒绝非数字段", !AppVersion.isValid("1.a"))
        check("拒绝空串", !AppVersion.isValid(""))
        check("拒绝构建号非数字", !AppVersion.isValidBuild("2b"))

        check("compare 相等", AppVersion.compare("1.1", "1.1") == .orderedSame)
        check("compare 高位更大", AppVersion.compare("1.2", "1.1") == .orderedDescending)
        check("compare 补零后相等", AppVersion.compare("1.1", "1.1.0") == .orderedSame)
        check("compare 修订号更大", AppVersion.compare("1.1.1", "1.1") == .orderedDescending)
        check("compare 按数值而非字典序", AppVersion.compare("2.0", "10.0") == .orderedAscending)
        check("compare 非法输入返回 nil", AppVersion.compare("bad", "1.1") == nil)
        check("isNewer 递增成立", AppVersion.isNewer("1.2", than: "1.1"))
        check("isNewer 同版本不成立", !AppVersion.isNewer("1.1", than: "1.1"))
        check("isNewer 倒退不成立", !AppVersion.isNewer("0.9", than: "1.1"))

        let c = AppVersion.bundleCheck()
        if case .mismatch = c {
            check("包内 plist 与源码版本一致：\(c.description)", false)
        } else {
            check("包内 plist 核对通过（\(c.description)）", true)
        }

        print("结果: \(pass) 通过 / \(fail) 失败")
        if fail > 0 { exit(1) }
    }
}
SWIFT
  echo "  · 已生成 ${SWIFT_FILE}（${NM_VERSION} / build ${NM_BUILD}）"
}

cmd_print() {
  load
  echo "MARKETING      $NM_VERSION"
  echo "BUILD          $NM_BUILD"
  echo "TAG            $NM_TAG"
  echo "ZIP            $NM_ZIP"
  echo "BUNDLE ID      $(pb_get CFBundleIdentifier "$TEMPLATE_PLIST")"
}

cmd_sync() {
  load
  gen_swift
  pb_set "$TEMPLATE_PLIST"
  echo "  · 已回填 ${TEMPLATE_PLIST}（${NM_VERSION} / ${NM_BUILD}）"
}

cmd_stamp() {
  load
  [[ $# -ge 1 ]] || die "用法：./scripts/version.sh stamp <plist 路径>"
  pb_set "$1"
  echo "  · 已写入 $1 → $NM_VERSION ($NM_BUILD)"
}

# 只在「当前生效」的文档里替换版本引用；历史日志 / 设计档案不碰。
live_docs() {
  local f
  for f in README.md dist/README.md .gitignore dist/SHA256SUMS; do
    if [[ -f "$ROOT/$f" ]]; then echo "$ROOT/$f"; fi
  done
  return 0
}

cmd_bump() {
  local new="${1:-}" newbuild="${2:-}"
  load
  [[ -n "$new" ]] || die "用法：./scripts/version.sh bump <新版本> [构建号]，例如 bump 1.2"
  [[ "$new" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "版本号格式非法：$new"
  ver_gt "$new" "$NM_VERSION" || die "新版本 $new 必须大于当前版本 $NM_VERSION"

  local old="$NM_VERSION" oldbuild="$NM_BUILD"
  local old_rx="${old//./\\.}"
  local oldtag_rx="v${old//./\\.}(\\.[0-9]+)*"
  if [[ -z "$newbuild" ]]; then newbuild=$((NM_BUILD + 1)); fi
  [[ "$newbuild" =~ ^[0-9]+$ ]] || die "构建号格式非法：$newbuild"
  (( newbuild > NM_BUILD )) || die "构建号必须递增（当前 ${NM_BUILD}）"

  /usr/bin/sed -i '' -E \
    -e "s/^MARKETING=.*/MARKETING=$new/" \
    -e "s/^BUILD=.*/BUILD=$newbuild/" "$VERSION_FILE"
  load   # 用新值刷新派生名

  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    /usr/bin/sed -i '' -E \
      -e "s/NASMonitor-${old_rx}\\.zip/NASMonitor-$new.zip/g" \
      -e "s/${oldtag_rx}/v$new/g" \
      -e "s/版本 ${old_rx}/版本 $new/g" \
      "$f"
    echo "  · 已更新 $(basename "$f")"
  done < <(live_docs)

  cmd_sync >/dev/null
  echo "✓ 版本已推进 $old → ${new}（build $oldbuild → ${newbuild}）"
  echo ""
  echo "发布清单（不要跳过）："
  echo "  1. 改代码 → ./build.sh（会自动 sync + 核对包内 plist）"
  echo "  2. \$BIN --version  与  \$BIN --version-selftest"
  echo "  3. 重打 ${NM_ZIP}，刷新 dist/SHA256SUMS 里的哈希"
  echo "  4. ./scripts/version.sh check     # 全量门禁，不通过不许发"
  echo "  5. git commit && git tag $NM_TAG && 上传 Release 资源"
  if [[ -f "$ROOT/dist/NASMonitor-$old.zip" ]]; then
    echo "  ! dist/ 里还有旧包 NASMonitor-$old.zip，重打包后请归档或移除"
  fi
}

cmd_check() {
  local skip_dist=0
  [[ "${1:-}" == "--skip-dist" ]] && skip_dist=1
  load
  local errs=0
  ok()  { echo "  ✓ $*"; }
  bad() { echo "  ✗ $*" >&2; errs=$((errs + 1)); }

  echo "NASMonitor 版本门禁 · $NM_VERSION (build $NM_BUILD) · tag $NM_TAG"

  # 1. 生成的 Swift 常量
  if grep -qF "static let marketing = \"$NM_VERSION\"" "$SWIFT_FILE" 2>/dev/null &&
     grep -qF "static let build = \"$NM_BUILD\"" "$SWIFT_FILE" 2>/dev/null; then
    ok "Version.swift 常量与 VERSION 一致"
  else
    bad "Version.swift 与 VERSION 不一致（跑 ./scripts/version.sh sync）"
  fi

  # 2. plist 模板 / 已组装 .app
  local p
  for p in "$TEMPLATE_PLIST" "$BUNDLE_PLIST"; do
    [[ -f "$p" ]] || continue
    local s b
    s="$(pb_get CFBundleShortVersionString "$p")"
    b="$(pb_get CFBundleVersion "$p")"
    if [[ "$s" == "$NM_VERSION" && "$b" == "$NM_BUILD" ]]; then
      ok "$(basename "$(dirname "$p")")/Info.plist = $NM_VERSION ($NM_BUILD)"
    else
      bad "$p 版本不一致：$s / ${b}（期望 ${NM_VERSION} / ${NM_BUILD}）"
    fi
  done

  # 3. 关于页不得再写死版本号
  local sv="$ROOT/Sources/NASMonitor/SettingsView.swift"
  if grep -qF 'AppVersion.display' "$sv" 2>/dev/null; then
    if /usr/bin/grep -Eq '版本 [0-9]+\.[0-9]+' "$sv"; then
      bad "SettingsView.swift 还残留硬编码版本号"
    else
      ok "关于页读 AppVersion.display，无硬编码版本"
    fi
  else
    bad "SettingsView.swift 未使用 AppVersion.display"
  fi

  # 4. 源码里不得残留旧版 zip 名 / 旧 tag（Version.swift 除外，它是新值）
  local stale
  stale="$(/usr/bin/grep -RInE "NASMonitor-[0-9]+\.[0-9]+(\.[0-9]+)?\.zip|releases/(download|tag)/v[0-9]+\.[0-9]+" \
            "$ROOT/Sources" "$ROOT/Resources" 2>/dev/null \
            | /usr/bin/grep -v "NASMonitor-$NM_VERSION.zip" || true)"
  if [[ -z "$stale" ]]; then
    ok "源码 / 资源里无旧版本包名残留"
  else
    bad "源码 / 资源里有旧版本包名残留："
    echo "$stale" >&2
  fi

  # 5. 当前文档引用
  local readme="$ROOT/README.md" doc
  if [[ -f "$readme" ]]; then
    if /usr/bin/grep -qF "$NM_ZIP" "$readme" || [[ $skip_dist -eq 1 ]]; then
      ok "README.md 引用当前包名 $NM_ZIP"
    else
      bad "README.md 没有引用当前包名 $NM_ZIP"
    fi
  fi
  for doc in dist/README.md .gitignore; do
    [[ -f "$ROOT/$doc" ]] || continue
    if /usr/bin/grep -qF "NASMonitor-" "$ROOT/$doc"; then
      local wrong
      wrong="$(/usr/bin/grep -oE 'NASMonitor-[0-9]+\.[0-9]+(\.[0-9]+)?\.zip' "$ROOT/$doc" \
               | /usr/bin/sort -u | /usr/bin/grep -vF "$NM_ZIP" || true)"
      if [[ -z "$wrong" ]]; then
        ok "$doc 只引用当前包名"
      else
        bad "$doc 引用了旧包名：$(echo "$wrong" | tr '\n' ' ')"
      fi
    fi
  done

  # 6. 发布包与校验和（公开副本才有 dist/）
  if [[ -f "$ROOT/dist/SHA256SUMS" ]]; then
    if [[ $skip_dist -eq 1 ]]; then
      ok "跳过 dist/ 校验（--skip-dist）"
    else
      local sums="$ROOT/dist/SHA256SUMS" name hash
      name="$(/usr/bin/awk 'NR==1 {print $2}' "$sums")"
      if [[ "$name" == "$NM_ZIP" ]]; then
        ok "SHA256SUMS 文件名 = $NM_ZIP"
      else
        bad "SHA256SUMS 文件名 $name ≠ $NM_ZIP"
      fi
      if [[ -f "$ROOT/dist/$NM_ZIP" ]]; then
        hash="$(cd "$ROOT/dist" && /usr/bin/shasum -a 256 -c SHA256SUMS 2>/dev/null || true)"
        if [[ "$hash" == *": OK"* ]]; then
          ok "dist/$NM_ZIP 校验和有效"
        else
          bad "dist/$NM_ZIP 校验和不匹配（重打包后要刷新 SHA256SUMS）"
        fi
      else
        bad "缺少 dist/$NM_ZIP"
      fi
    fi
  fi

  if [[ -f "$ROOT/.gitignore" ]]; then
    local wl
    wl="$(/usr/bin/grep -E '^!dist/NASMonitor-.*\.zip' "$ROOT/.gitignore" || true)"
    if [[ "$wl" == "!dist/$NM_ZIP" ]]; then
      ok ".gitignore 白名单 = !dist/$NM_ZIP"
    else
      bad ".gitignore 白名单应为 !dist/${NM_ZIP}（当前：${wl}）"
    fi
  fi

  echo "────────────────────────────────"
  if (( errs > 0 )); then
    echo "✗ 版本门禁未通过：$errs 项不一致" >&2
    exit 1
  fi
  echo "✓ 版本门禁通过：VERSION / Swift / plist / 包名 / 校验和全部一致"
}

case "${1:-print}" in
  print) shift; cmd_print "$@" ;;
  sync)  shift; cmd_sync "$@" ;;
  stamp) shift; cmd_stamp "$@" ;;
  bump)  shift; cmd_bump "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) die "未知子命令：$1（可用 print / sync / stamp / bump / check）" ;;
esac
