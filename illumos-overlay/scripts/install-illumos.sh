#!/usr/bin/env bash
# =============================================================================
# install-illumos.sh — 在 OpenIndiana / illumos 上安装 illumos-x64 .NET SDK
#                      并修复交叉构建留下的 PNSE 空壳程序集
# -----------------------------------------------------------------------------
#
# 背景（为什么需要这个脚本）
# --------------------------
# 这套 SDK 由 dotnet VMR 交叉构建。交叉构建时 illumos 不在受支持的平台列表里，
# 于是少数「按平台分实现」的库被编成了 PlatformNotSupportedException 桩（空壳）：
# 类型/方法签名都在，但每个方法体只做一件事 —— 抛 PNSE。
#
# 影响：
#   System.Net.Security          -> NuGet 走 HTTPS 直接失败（NU1301 / NU3018）
#   System.Net.Quic              -> HTTP/3 不可用
#   System.IO.FileSystem.Watcher -> FileSystemWatcher 直接抛异常
#     （换 dll 只解决托管层；原生层是 ENOTSUP 桩，需 3.5 节的垫片才真正可用）
#
# 另外 illumos 的 CA 证书库不在 .NET/NuGet 默认查找的 /etc/ssl/certs，
# 且缺少微软代码签名链依赖的老根证书（DigiCert Assured ID Root CA），
# 会导致包签名校验失败（NU3018 signing certificate is not trusted）。
#
# 本脚本做的事（全部在安装时完成，幂等，可重复执行）
# --------------------------------------------------
#   1. 解压并落位 SDK 到安装前缀（默认 /opt/dotnet）
#   2. 安装 CA 证书（合并系统原有证书 + 内置 bundle，写全 .NET 会查的路径）
#   3. 扫描并识别 PNSE 空壳 dll（IL 体量判定，不依赖文件名硬编码）
#   4. 读出空壳 dll 声明的 TFM（如 net11.0），据此从官方源取对应版本的
#      Microsoft.NETCore.App.Runtime.linux-x64，逐个替换成真实现。
#      只替换「illumos 是空壳、而官方不是」的那些 —— Windows 专有 API
#      （如 System.Security.AccessControl）在两边都是桩，属正常，不动。
#   5. 写 /etc/profile.d/illumos-dotnet.sh
#        DOTNET_ROOT / PATH / SSL_CERT_FILE / SSL_CERT_DIR / DOTNET_ReadyToRun=0
#      DOTNET_ReadyToRun=0 是关键：替换进来的官方程序集带 R2R 预编译代码，
#      illumos 加载会 core dump，必须强制 JIT。
#   6. FileSystemWatcher 原生垫片（见 3.5 节）：用 portfs 实现用户态
#      inotify，再以 PAL 垫片替换 libSystem.Native.so 里的三个 ENOTSUP 桩。
#      仅当 watcher dll 被替换过时才做；失败自动回滚。
#   7. 自检：dotnet --version + 在线 restore 冒烟
#
# 用法
# ----
#   # A) 和 tar 包放在一起（推荐）
#   sudo bash install-illumos.sh dotnet-sdk-*-illumos-x64.tar.gz
#
#   # B) 已经解压好了，进入 SDK 根目录
#   sudo bash install-illumos.sh
#
#   # C) 指定前缀 / 指定 runtime pack 版本 / 自定义下载源
#   sudo bash install-illumos.sh --prefix /opt/dotnet --pack 11.0.0-rc.1.26425.128
#
# 常用选项
# --------
#   --prefix <dir>      安装前缀（默认 /opt/dotnet）
#   --pack <版本>        指定 runtime pack 版本（默认按空壳 dll 的 TFM 自动选择）
#   --pack-base <URL>   自定义下载源（默认 nuget.org → 华为云 → dnceng 依次尝试）
#   --pack-file <nupkg> 使用本地已有的 runtime pack，不联网
#   --dll-list <a,b>    手动指定要替换的 dll（跳过自动扫描）
#   --no-dlls           不替换 dll（只装证书 / 环境变量）
#   --no-certs          不装证书
#   --no-profile        不写 /etc/profile.d
#   --no-fsw-shim       不做 FileSystemWatcher 垫片（保持 ENOTSUP 桩）
#   --fsw-shim          强制做/重做 FileSystemWatcher 垫片（dll 已换过也能用）
#   --force             覆盖已存在的前缀（默认改名保留为 .old-<时间戳>）
#   --dry-run           只检测与报告，不改动任何东西
#   -y                  不询问
#   -h | --help         帮助
# =============================================================================
set -euo pipefail

PREFIX="/opt/dotnet"
PACK_VER=""
PACK_BASE=""
PACK_FILE=""
DLL_LIST=""
DO_DLLS=1
DO_CERTS=1
DO_PROFILE=1
DO_FSW=1
FSW_NEEDED=0
FSW_FORCE=0
FORCE=0
DRY=0
TARBALL=""

usage() { awk 'NR>1 && /^set -euo pipefail/ {exit} NR>1 {sub(/^# ?/,""); print}' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)     PREFIX="${2:?--prefix 需要目录参数}"; shift 2 ;;
    --prefix=*)   PREFIX="${1#*=}"; shift ;;
    --pack)       PACK_VER="${2:?--pack 需要版本号}"; shift 2 ;;
    --pack=*)     PACK_VER="${1#*=}"; shift ;;
    --pack-base)  PACK_BASE="${2:?--pack-base 需要 URL}"; shift 2 ;;
    --pack-base=*) PACK_BASE="${1#*=}"; shift ;;
    --pack-file)  PACK_FILE="${2:?--pack-file 需要文件路径}"; shift 2 ;;
    --pack-file=*) PACK_FILE="${1#*=}"; shift ;;
    --dll-list)   DLL_LIST="${2:?--dll-list 需要逗号分隔的 dll 名}"; shift 2 ;;
    --dll-list=*) DLL_LIST="${1#*=}"; shift ;;
    --no-dlls)    DO_DLLS=0; shift ;;
    --no-certs)   DO_CERTS=0; shift ;;
    --no-profile) DO_PROFILE=0; shift ;;
    --no-fsw-shim) DO_FSW=0; shift ;;
    --fsw-shim)   DO_FSW=1; FSW_FORCE=1; shift ;;
    --force)      FORCE=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    -y|--yes)     shift ;;
    -h|--help)    usage ;;
    -*)           echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
    *)            TARBALL="$1"; shift ;;
  esac
done

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

c_info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
c_die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || c_die "需要 root 权限，请用 sudo 运行"

# ---------------------------------------------------------------------------
# 工具探测
# ---------------------------------------------------------------------------
TAR="tar"
for c in gtar /usr/bin/gtar /usr/sfw/bin/gtar tar; do
  if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then TAR="$c"; break; fi
done
c_info "tar: $(command -v $TAR)"

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then
    if "$c" -c 'import struct, sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then PY="$c"; break; fi
  fi
done
[ -n "$PY" ] || c_die "需要 python3 来识别 PNSE 空壳程序集（OpenIndiana: pkg install runtime/python-3）"

command -v curl >/dev/null 2>&1 || c_die "需要 curl"
command -v unzip >/dev/null 2>&1 || c_die "需要 unzip"

# ---------------------------------------------------------------------------
# 内嵌 IL 分析器
#   PNSE 空壳的每个方法体恰好是 11 字节：
#       ldstr <msg>; newobj PlatformNotSupportedException::.ctor(string); throw
#   真实现的平均每方法 IL 远大于此（实测 40~70 字节）。
#   这个判据不依赖文件名，也不依赖会被完整版一并携带的资源字符串
#   （"X is not supported on this platform." 两边都有，不能当特征）。
# ---------------------------------------------------------------------------
ILCHECK="$(mktemp "${TMPDIR:-/tmp}/ilcheck.XXXXXX.py")"
trap 'rm -f "$ILCHECK"' EXIT

cat > "$ILCHECK" <<'PYEOF'
#!/usr/bin/env python3
"""ilcheck.py — 判定 .NET 程序集是否为 PNSE 空壳（平台不支持桩）。"""
import os
import re
import struct
import sys

TFM_RE = re.compile(rb"\.NETCoreApp,\s*Version=v(\d+)\.(\d+)")

SHELL_MIN_METHODS = 20
SHELL_MAX_AVG_IL = 25.0
SHELL_MIN_TINY_RATIO = 0.5


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


class Err(Exception):
    pass


def open_pe(data):
    if data[:2] != b"MZ":
        raise Err("no MZ")
    e = u32(data, 0x3C)
    if data[e:e + 4] != b"PE\0\0":
        raise Err("bad PE sig")
    nsec = u16(data, e + 6)
    opt_size = u16(data, e + 20)
    opt = e + 24
    magic = u16(data, opt)
    if magic == 0x10B:
        dd = opt + 96
    elif magic == 0x20B:
        dd = opt + 112
    else:
        raise Err("bad magic")
    secs = []
    so = opt + opt_size
    for i in range(nsec):
        b = so + i * 40
        vsz = u32(data, b + 8)
        va = u32(data, b + 12)
        sraw = u32(data, b + 16)
        praw = u32(data, b + 20)
        secs.append((va, max(vsz, sraw), praw))

    def r2o(rva):
        for va, sz, praw in secs:
            if va <= rva < va + sz:
                return praw + (rva - va)
        raise Err("rva oob")

    return dd, r2o


def streams(data, dd, r2o):
    cli_rva = u32(data, dd + 14 * 8)
    if cli_rva == 0:
        raise Err("no CLI hdr")
    md = r2o(u32(data, r2o(cli_rva) + 8))
    if u32(data, md) != 0x424A5342:
        raise Err("bad md sig")
    p = (md + 16 + u32(data, md + 12) + 3) & ~3
    n = u16(data, p + 2)
    p += 4
    out = {}
    for _ in range(n):
        off = u32(data, p)
        q = p + 8
        nm = b""
        while data[q] != 0:
            nm += bytes([data[q]])
            q += 1
        out[nm.decode("utf-8", "replace")] = md + off
        p = (q + 1 + 3) & ~3
    return out


def analyze(path):
    """返回 (带方法体的方法数, 平均 IL 字节, 11 字节桩占比)。"""
    data = open(path, "rb").read()
    dd, r2o = open_pe(data)
    st = streams(data, dd, r2o)
    key = "#~" if "#~" in st else ("#-" if "#-" in st else None)
    if not key:
        raise Err("no table stream")
    tabs = st[key]
    heap = data[tabs + 6]
    valid = struct.unpack_from("<Q", data, tabs + 8)[0]
    p = tabs + 24
    rows = {}
    for i in range(64):
        if (valid >> i) & 1:
            rows[i] = u32(data, p)
            p += 4
    strw = 4 if heap & 1 else 2
    guidw = 4 if heap & 2 else 2
    blobw = 4 if heap & 4 else 2

    def simple(t):
        return 4 if rows.get(t, 0) >= 65536 else 2

    def coded(tables, bits):
        m = max([rows.get(t, 0) for t in tables] or [0])
        return 4 if m >= (1 << (16 - bits)) else 2

    rs = {
        0: 2 + strw + guidw + guidw + guidw,
        1: coded([0, 0x1A, 0x23, 1], 2) + strw + strw,
        2: 4 + strw + strw + coded([2, 1, 0x1B], 2) + simple(4) + simple(6),
        3: simple(4),
        4: 2 + strw + blobw,
        5: simple(6),
        6: 4 + 2 + 2 + strw + blobw + simple(8),
    }
    off = p
    for i in range(6):
        if i in rows:
            off += rows[i] * rs[i]

    nmeth = total = tiny = 0
    for i in range(rows.get(6, 0)):
        rva = u32(data, off + i * rs[6])
        if rva == 0:
            continue
        try:
            b = r2o(rva)
        except Err:
            continue
        hdr = data[b]
        if (hdr & 3) == 2:
            cs = hdr >> 2
        elif (hdr & 3) == 3:
            cs = u32(data, b + 4)
        else:
            continue
        nmeth += 1
        total += cs
        if cs == 11:
            tiny += 1
    avg = total / nmeth if nmeth else 0.0
    ratio = tiny / nmeth if nmeth else 0.0
    return nmeth, avg, ratio


def is_shell(nmeth, avg, ratio):
    return (nmeth >= SHELL_MIN_METHODS and avg < SHELL_MAX_AVG_IL
            and ratio > SHELL_MIN_TINY_RATIO)


def read_tfm(path):
    """读出程序集声明的 .NETCoreApp 版本，如 net11.0。"""
    with open(path, "rb") as f:
        m = TFM_RE.search(f.read())
    if not m:
        return ""
    major, minor = m.group(1), m.group(2)
    # 正则匹配的是 bytes，不同 Python 版本 group() 返回 bytes，需显式解码
    if isinstance(major, bytes):
        major, minor = major.decode("ascii"), minor.decode("ascii")
    return "net%s.%s" % (major, minor)


def dlls(d):
    if not os.path.isdir(d):
        return []
    return sorted(f for f in os.listdir(d) if f.endswith(".dll"))


def main():
    mode = sys.argv[1]
    if mode == "tfm":
        print(read_tfm(sys.argv[2]))
    elif mode == "stat":
        for f in dlls(sys.argv[2]):
            try:
                nmeth, avg, ratio = analyze(os.path.join(sys.argv[2], f))
            except Exception:
                continue
            print("%s\t%d\t%.1f\t%.2f\t%s" % (f, nmeth, avg, ratio,
                  "SHELL" if is_shell(nmeth, avg, ratio) else "ok"))
    elif mode == "shell":
        for f in dlls(sys.argv[2]):
            try:
                nmeth, avg, ratio = analyze(os.path.join(sys.argv[2], f))
            except Exception:
                continue
            if is_shell(nmeth, avg, ratio):
                print(f)
    elif mode == "plan":
        src, official = sys.argv[2], sys.argv[3]
        off = {}
        for f in dlls(official):
            try:
                nmeth, avg, ratio = analyze(os.path.join(official, f))
                off[f] = is_shell(nmeth, avg, ratio)
            except Exception:
                off[f] = True          # 解析不了就不冒险替换
        for f in dlls(src):
            if f not in off:
                continue
            try:
                nmeth, avg, ratio = analyze(os.path.join(src, f))
            except Exception:
                continue
            if is_shell(nmeth, avg, ratio) and not off[f]:
                print(f)
    else:
        sys.stderr.write("unknown mode\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
PYEOF

# ---------------------------------------------------------------------------
# 1) 解压 / 落位
# ---------------------------------------------------------------------------
STAGE=""
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || c_die "找不到 tar 包: $TARBALL"
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-install.XXXXXX")"
  c_info "解压 $(basename "$TARBALL") -> $STAGE （约 2.5GB，请稍等）"
  "$TAR" xzf "$TARBALL" -C "$STAGE"
elif [ -x "$SELF_DIR/dotnet" ] && [ -d "$SELF_DIR/shared" ]; then
  STAGE="$SELF_DIR"
  c_info "就地安装（SDK 根: $STAGE）"
elif [ -x "$PREFIX/dotnet" ] && [ -d "$PREFIX/shared" ]; then
  # 幂等重跑：前缀里已经装了，直接就地修补
  STAGE="$PREFIX"
  c_info "使用已安装的前缀 $PREFIX（就地修补）"
else
  c_die "当前目录不像 SDK 根。请解压后进入该目录，或把 tar 包作为参数传进来"
fi

[ -x "$STAGE/dotnet" ] || c_die "$STAGE 下没有可执行的 dotnet"
[ -d "$STAGE/shared" ] || c_die "$STAGE 下没有 shared/"

if [ "$STAGE" != "$PREFIX" ]; then
  if [ "$DRY" = "1" ]; then
    c_info "[dry-run] 将落位 $STAGE -> $PREFIX"
  else
    mkdir -p "$(dirname "$PREFIX")"
    if [ -e "$PREFIX" ] && [ "$FORCE" = "0" ]; then
      OLD="$PREFIX.old-$(date +%Y%m%d-%H%M%S)"
      c_info "前缀已存在，原目录改名为 $OLD"
      mv "$PREFIX" "$OLD"
    elif [ "$FORCE" = "1" ] && [ -e "$PREFIX" ]; then
      c_info "--force：删除已存在的 $PREFIX"
      rm -rf "$PREFIX"
    fi
    c_info "落位 $STAGE -> $PREFIX"
    mv "$STAGE" "$PREFIX"
  fi
fi
STAGE="$PREFIX"

FX_ROOT="$PREFIX/shared/Microsoft.NETCore.App"
[ -d "$FX_ROOT" ] || c_die "$FX_ROOT 不存在，不像是完整的 SDK"
FX="$(ls -d "$FX_ROOT"/*/ 2>/dev/null | tail -1)"
FX="${FX%/}"
RT_VER="$(basename "$FX")"
c_info "框架目录: $FX"
c_info "运行时版本: $RT_VER"

# ---------------------------------------------------------------------------
# 2) CA 证书
# ---------------------------------------------------------------------------
if [ "$DO_CERTS" = "1" ]; then
  CA_SRC=""
  for c in "$SELF_DIR/illumos-ca-bundle.crt" "$SELF_DIR/certs/illumos-ca-bundle.crt" \
           "$PREFIX/illumos-ca-bundle.crt" /opt/illumos-ca-bundle.crt; do
    [ -s "$c" ] && { CA_SRC="$c"; break; }
  done

  if [ -z "$CA_SRC" ]; then
    c_warn "找不到 illumos-ca-bundle.crt，跳过证书安装（NuGet 会报 NU3018）"
  elif [ "$DRY" = "1" ]; then
    c_ok "[dry-run] 将从 $CA_SRC 安装证书到 /etc/ssl/certs 等路径"
  else
    c_info "安装 CA 证书（bundle: $CA_SRC）"
    mkdir -p /etc/ssl/certs /etc/pki/tls/certs /usr/local/share/ca-certificates
    TMPCA="$(mktemp)"
    cat "$CA_SRC" > "$TMPCA"
    # 并入系统原有证书，而不是覆盖
    for s in /etc/certs/ca-certificates.crt /etc/openssl/certs/ca-certificates.crt; do
      [ -s "$s" ] && { cat "$s" >> "$TMPCA"; c_info "  并入系统证书 $s"; break; }
    done
    cp -f "$TMPCA" /etc/ssl/certs/ca-certificates.crt
    cp -f "$TMPCA" /etc/pki/tls/certs/ca-bundle.crt
    cp -f "$TMPCA" /usr/local/share/ca-certificates/ca-certificates.crt
    [ -d /etc/certs ] && cp -f "$TMPCA" /etc/certs/ca-certificates.crt || true

    # 单证书 + 哈希链接（部分库按目录扫描）
    if command -v openssl >/dev/null 2>&1; then
      ( cd /etc/ssl/certs
        awk 'BEGIN{n=0} /BEGIN CERT/{n++; f=sprintf("illumos-%04d.pem", n)} {if(f) print > f} /END CERT/{close(f); f=""}' "$TMPCA"
        for f in illumos-*.pem; do
          [ -e "$f" ] || continue
          h="$(openssl x509 -hash -noout -in "$f" 2>/dev/null || true)"
          [ -n "$h" ] && ln -sf "$f" "$h.0" 2>/dev/null || true
        done ) || c_warn "  拆分证书出错（不影响主 bundle）"
    fi
    rm -f "$TMPCA"
    TOTAL="$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt || echo 0)"
    c_ok "证书已装到 /etc/ssl/certs/ca-certificates.crt（共 $TOTAL 张）"
    if grep -q 'DigiCert Assured ID Root CA' /etc/ssl/certs/ca-certificates.crt 2>/dev/null; then
      c_ok "  含 DigiCert Assured ID Root CA（NuGet 签名链需要）"
    else
      c_warn "  缺 DigiCert Assured ID Root CA，NuGet 可能仍报 NU3018"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3) 识别并替换 PNSE 空壳 dll
# ---------------------------------------------------------------------------
MJR=""
if [ "$DO_DLLS" = "1" ]; then
  c_info "扫描 PNSE 空壳程序集 ..."
  SHELLS="$("$PY" "$ILCHECK" shell "$FX" 2>/dev/null || true)"

  if [ -n "$DLL_LIST" ]; then
    SHELLS="$(echo "$DLL_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true)"
    c_info "使用 --dll-list 指定的列表"
  fi

  if [ -z "$SHELLS" ]; then
    c_ok "未发现空壳程序集（或该构建已修好），跳过"
  else
    echo "$SHELLS" | sed 's/^/    /'

    # --- 3a) 从空壳 dll 读出 TFM，决定要取哪个版本的 runtime pack ---
    TFM=""
    for f in $SHELLS; do
      [ -f "$FX/$f" ] || continue
      t="$("$PY" "$ILCHECK" tfm "$FX/$f" 2>/dev/null || true)"
      [ -n "$t" ] && { TFM="$t"; break; }
    done
    if [ -z "$TFM" ]; then
      MAJOR0="$(echo "$RT_VER" | cut -d. -f1)"
      TFM="net${MAJOR0}.0"
      c_warn "无法从空壳 dll 读出 TFM，按运行时主版本推断: $TFM"
    else
      c_info "空壳 dll 声明的 TFM: $TFM"
    fi
    MMR="${TFM#net}"                                   # 11.0
    MJR="${MMR%%.*}"                                   # 11
    BUILDNO="$(echo "$RT_VER" | sed -n 's/.*\.\([0-9][0-9][0-9][0-9][0-9][0-9]*\)\..*/\1/p')"
    # 产品版本前缀，如 12.0.0-alpha.1.26473（去掉末尾的构建修订号）。
    # 用它优先锁定同一产品版本 / 同一构建号的 runtime pack，保证程序集版本一致。
    PRODPREF="$(echo "$RT_VER" | sed 's/\.[0-9][0-9]*$//')"
    c_info "主版本=$MJR  TFM=$MMR  构建号=${BUILDNO:-未知}  产品版本前缀=$PRODPREF"

    # --- 3b) 解析 runtime pack 版本 ---
    # 选择原则：版本一致优先于下载速度，尽量用官方（国外）源；国内镜像仅兜底。
    #   nuget.org        正式发布版（最快，实测 1.5MB/s）
    #   dnceng dotnet12  与 SDK 同产品版本（12.0.0-alpha.* 同构建号）的 nightly
    #   dnceng dotnet11  同 TFM 大版本（net11.0）的 nightly
    #   华为云            国内镜像（兜底）
    PRODMAJOR="$(echo "$RT_VER" | cut -d. -f1)"
    SRC_NUGET="https://api.nuget.org/v3-flatcontainer"
    SRC_DNCENG_PROD="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${PRODMAJOR}/nuget/v3/flat2"
    SRC_DNCENG_TFM="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${MJR}/nuget/v3/flat2"
    SRC_HUAWEI="https://repo.huaweicloud.com/artifactory/api/nuget/v3/nuget-remote"
    if [ -n "$PACK_BASE" ]; then
      SRC_NUGET="$PACK_BASE"
      c_info "自定义下载源: $PACK_BASE"
    fi
    SOURCES="$SRC_NUGET
$SRC_DNCENG_PROD
$SRC_DNCENG_TFM
$SRC_HUAWEI"

    if [ -z "$PACK_VER" ]; then
      if [ -n "$PACK_FILE" ]; then
        PACK_VER=""
      else
        c_info "查询可用的 runtime pack 版本 ..."
        PACK_VER="$("$PY" - "$SOURCES" "$MMR" "$MJR" "${BUILDNO:-}" "$PRODPREF" <<'PYEOF'
import json
import sys
import urllib.request

PKG = "microsoft.netcore.app.runtime.linux-x64"
srcblob, mmr, mjr, buildno, prodpref = sys.argv[1:6]

# 按给出顺序定优先级（靠前更优先），仅用于同分时的取舍
bases = []
for b in srcblob.splitlines():
    b = b.strip()
    if b and b not in bases:
        bases.append(b)


def versions_of(base):
    url = "%s/%s/index.json" % (base.rstrip("/"), PKG)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r).get("versions", [])


cands = []
for idx, base in enumerate(bases):
    rank = 100 - idx * 5
    try:
        vers = versions_of(base)
    except Exception:
        continue
    for v in vers:
        if prodpref and v.startswith(prodpref + "."):
            s = 100000                  # 同一产品版本 + 同一构建号：最匹配
        elif buildno and (".%s." % buildno) in v:
            s = 10000                   # 同一构建号
        elif v.startswith(mmr + "."):
            s = 1000                    # 同 TFM 大版本
        elif v.startswith(mjr + "."):
            s = 100                     # 同主版本
        else:
            continue
        if "-" not in v:
            s += 10                     # 正式版优先于预览版
        cands.append((s, v, base))

if cands:
    cands.sort(key=lambda x: (x[0], x[1], x[2]))
    print("%s|%s" % (cands[-1][1], cands[-1][2]))
PYEOF
)"
        [ -n "$PACK_VER" ] || c_die "找不到可用的 runtime pack 版本，请用 --pack <版本> 手动指定"
      fi
    fi

    if [ "$DRY" = "1" ]; then
      c_ok "[dry-run] runtime pack: ${PACK_VER:-<--pack-file 指定>}"
      c_ok "[dry-run] 待替换: $(echo "$SHELLS" | tr '\n' ' ')"
    else
      PVER=""; PBASE=""
      if [ -n "$PACK_VER" ]; then
        PVER="${PACK_VER%%|*}"
        PBASE="${PACK_VER##*|}"
        [ "$PBASE" = "$PVER" ] && PBASE="$SRC_NUGET"
        c_info "runtime pack 版本: $PVER"
      fi

      WORK="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-pack.XXXXXX")"
      NUPKG="$WORK/pack.nupkg"

      # 境外夜间源较慢，超时给足（默认 1 小时，可用 DL_TIMEOUT 覆盖）
      DL_TIMEOUT="${DL_TIMEOUT:-3600}"
      # 下载过的 pack 缓存起来，重跑/多机安装时不必再下
      PACK_CACHE="${PACK_CACHE:-/var/cache/illumos-dotnet}"
      PKGID="microsoft.netcore.app.runtime.linux-x64"
      CACHED="$PACK_CACHE/$PKGID.$PVER.nupkg"

      if [ -n "$PACK_FILE" ]; then
        [ -f "$PACK_FILE" ] || c_die "找不到 --pack-file: $PACK_FILE"
        cp -f "$PACK_FILE" "$NUPKG"
        c_info "使用本地 pack: $PACK_FILE"
      elif [ -n "$PVER" ] && [ -s "$CACHED" ]; then
        c_info "使用缓存 pack: $CACHED（$(stat -c%s "$CACHED") 字节）"
        cp -f "$CACHED" "$NUPKG"
      else
        OKDL=0
        for B in "$PBASE" $SOURCES; do
          [ -n "$B" ] || continue
          U="${B%/}/$PKGID/$PVER/$PKGID.$PVER.nupkg"
          c_info "下载 $U"
          c_info "  超时上限 ${DL_TIMEOUT}s（境外源可能较慢，请耐心等待）"
          if curl -fL --connect-timeout 30 --max-time "$DL_TIMEOUT" \
                  --retry 3 --retry-delay 5 \
                  --progress-bar -o "$NUPKG" "$U"; then
            OKDL=1; break
          fi
          c_warn "  该源失败，换下一个"
        done
        [ "$OKDL" = "1" ] || c_die "所有源都下载失败（可用 --pack-file 指定本地包）"
        if [ -n "$PVER" ] && mkdir -p "$PACK_CACHE" 2>/dev/null; then
          cp -f "$NUPKG" "$CACHED" 2>/dev/null && c_info "已缓存到 $CACHED" || true
        fi
      fi
      c_ok "pack 大小 $(stat -c%s "$NUPKG" 2>/dev/null || echo '?') 字节"

      # 解出官方 linux-x64 的托管 dll。
      # 不硬编码 lib 目录名：先看包里实际有哪些 netX.Y，优先取与空壳 TFM 一致的那个。
      OFFDIR="$WORK/official"
      mkdir -p "$OFFDIR" "$WORK/x"
      AVAIL_LIBS="$(unzip -Z1 "$NUPKG" 2>/dev/null \
        | sed -n 's#^runtimes/linux-x64/lib/\(net[0-9][0-9.]*\)/.*#\1#p' | sort -u)"
      USE_LIB=""
      for L in $AVAIL_LIBS; do
        # 目录名形如 net11.0，$TFM 也是 net11.0；$MMR 是去掉 net 前缀的 11.0
        [ "$L" = "$TFM" ] && USE_LIB="$L"
      done
      if [ -z "$USE_LIB" ]; then
        USE_LIB="$(echo "$AVAIL_LIBS" | tail -1)"
      fi
      [ -n "$USE_LIB" ] || c_die "pack 里没有 runtimes/linux-x64/lib/net* 目录"
      [ "$USE_LIB" = "$TFM" ] || c_warn "包内没有 $TFM，改用 $USE_LIB"
      c_info "使用包内 lib 目录: $USE_LIB"

      unzip -q -o "$NUPKG" "runtimes/linux-x64/lib/$USE_LIB/*" -d "$WORK/x" \
        || c_die "从 pack 里解 $USE_LIB 失败"
      cp -f "$WORK/x/runtimes/linux-x64/lib/$USE_LIB/"*.dll "$OFFDIR/" 2>/dev/null || true
      OFFCNT="$(ls "$OFFDIR"/*.dll 2>/dev/null | wc -l | tr -d ' ')"
      [ "${OFFCNT:-0}" -gt 0 ] || c_die "pack 里没有解出任何 dll"
      c_ok "官方 $USE_LIB 参考 dll: $OFFCNT 个"

      # --- 3c) 只替换「illumos 是空壳 且 官方不是空壳」的 ---
      if [ -n "$DLL_LIST" ]; then
        PLAN="$SHELLS"
      else
        PLAN="$("$PY" "$ILCHECK" plan "$FX" "$OFFDIR" 2>/dev/null || true)"
      fi

      if [ -z "$PLAN" ]; then
        c_ok "无需替换（空壳在官方版里同样是桩，属正常）"
      else
        BK="$PREFIX/.pnse-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BK"
        n=0
        for f in $PLAN; do
          if [ ! -f "$OFFDIR/$f" ]; then
            c_warn "  官方包中没有 $f，跳过"
            continue
          fi
          cp -p "$FX/$f" "$BK/$f"
          cp -f "$OFFDIR/$f" "$FX/$f"
          c_ok "  已替换 $f（$(stat -c%s "$BK/$f") -> $(stat -c%s "$FX/$f") 字节）"
          n=$((n + 1))
        done
        c_ok "共替换 $n 个程序集，原件备份在 $BK"
        case "$(echo "$PLAN" | tr '\n' ' ')" in
          *"System.IO.FileSystem.Watcher.dll"*) FSW_NEEDED=1 ;;
        esac
      fi
      rm -rf "$WORK"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3.5) FileSystemWatcher 原生垫片（PAL shim -> 用户态 inotify on portfs）
# ---------------------------------------------------------------------------
# 背景
#   第 3 步把 System.IO.FileSystem.Watcher.dll 换成了官方 linux 版，托管层于是
#   会去 P/Invoke libSystem.Native 里的三个入口。但那份 .so 是在 illumos 上
#   编译出来的，编译期 HAVE_INOTIFY=0，三个函数被打成 ENOTSUP 空壳
#   （各 24~26 字节），而且**完全不引用任何 inotify 符号**：
#
#       elfdump -d libSystem.Native.so | grep -c inotify   ->  0
#
#   于是两条常见思路都不成立（都实测过）：
#     - 装个用户态 inotify 库再 LD_PRELOAD  -> 无效，二进制里没有符号引用
#     - 用 LD_LIBRARY_PATH 换掉这个 .so     -> 无效，.NET 不按环境变量找框架库
#   唯一可行的做法是在 **PAL 层**做垫片，原理见下面 pal_shim.c 的头部注释。
#
# 本步做的事
#   1. 用 portfs(PORT_SOURCE_FILE) 实现一个用户态 inotify -> libillumos_inotify.so
#   2. 原 libSystem.Native.so 复制为 libSNative.so，并原地改掉它的 SONAME
#      （不改 SONAME 的话 ld 会以 "recording name conflict" 直接拒绝链接）
#   3. 编出同名垫片 libSystem.Native.so：只覆盖那 3 个符号，其余 200+ 符号
#      经 DT_NEEDED 依赖链透传到 libSNative.so
#   4. C 层自检（dlopen + dlsym + 实调），失败自动回滚
#
# 原始库只在首次安装时备份到 $PREFIX/.fsw-shim-orig/，可据此手动回滚：
#     cp -p $PREFIX/.fsw-shim-orig/*.libSystem.Native.so <框架目录>/libSystem.Native.so
#     rm -f <框架目录>/libSNative.so <框架目录>/libillumos_inotify.so
# ---------------------------------------------------------------------------
if [ "$DO_FSW" = "1" ] && { [ "$FSW_NEEDED" = "1" ] || [ "$FSW_FORCE" = "1" ]; }; then
  if [ "$DRY" = "1" ]; then
    c_ok "[dry-run] 将为 FileSystemWatcher 构建 portfs 用户态 inotify + PAL 垫片"
  elif ! command -v gcc >/dev/null 2>&1; then
    c_warn "未找到 gcc，跳过 FileSystemWatcher 垫片"
    c_warn "  -> FileSystemWatcher 仍会抛 PlatformNotSupportedException"
    c_warn "  -> 装上 gcc 后重跑本脚本即可：pkg install developer/gcc-13"
  elif [ ! -f /usr/include/port.h ]; then
    c_warn "缺 /usr/include/port.h（portfs 声明），跳过 FileSystemWatcher 垫片"
  else
    FSW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/illumos-fsw.XXXXXX")"
    ORIG_STORE="$PREFIX/.fsw-shim-orig"
    mkdir -p "$ORIG_STORE"
    c_info "构建 FileSystemWatcher 垫片（用户态 inotify on portfs）"

    cat > "$FSW_DIR/illumos_inotify.c" <<'ILLUMOS_INOTIFY_C_EOF'
/*
 * illumos_inotify.c — portfs(event ports) 后端的用户态 inotify 兼容层
 * =============================================================================
 *
 * 为什么需要它
 * ------------
 * illumos 没有内核 inotify：
 *   - illumos-gate 里不存在（/usr/include/sys/inotify.h 无、libc.so.1 零符号）
 *   - 只有 SmartOS / illumos-joyent 有，且从未 upstream
 *   - FreeBSD/OpenBSD 用的 libinotify 是 kqueue 后端，illumos 没有 kqueue
 * 所以只能基于 portfs(PORT_SOURCE_FILE) 在用户态模拟。
 *
 * 导出接口（与 Linux inotify 二进制兼容）
 * ---------------------------------------
 *   int inotify_init1(int flags);
 *   int inotify_add_watch(int fd, const char *path, uint32_t mask);
 *   int inotify_rm_watch(int fd, int wd);
 *
 * 设计
 * ----
 *   init1()  : port_create() 建事件端口；socketpair() 建"事件管道"；
 *              起一个后台线程，把 portfs 事件翻译成 struct inotify_event
 *              写进管道；返回**管道读端**作为 inotify fd。
 *              这样 read()/poll()/close() 的语义与真 inotify 一致。
 *   add_watch(): 目录 → port_associate 目录本身（拿 name 级变化：增/删/改名）
 *                     ＋ 对目录内每个普通文件 port_associate（拿内容修改）
 *                文件 → 直接 port_associate 该文件
 *
 * 两个必须处理的 portfs 语义差异
 * ------------------------------
 *   1) portfs 只通知"这个对象变了"，不告诉你变了什么
 *      → 目录级靠**快照比对**还原出 CREATE/DELETE/MOVED/MODIFY
 *   2) 事件被取走一次后关联**自动解除**
 *      → 每次 port_get 后必须重新 port_associate，否则只收到一次通知
 *
 * 已知限制
 * --------
 *   - 每个被监视目录最多对 ILLUMOS_INOTIFY_MAX_FILES 个文件做关联（默认 512），
 *     超出部分的内容修改不会被感知（name 级事件不受影响）
 *   - rename 靠 (isdir, size, mtime) 启发式配对，个别场景会退化成 DELETE+CREATE
 *   - IN_ACCESS / IN_OPEN / IN_CLOSE_* 不产生（portfs 无对应事件源）
 *
 * 构建
 * ----
 *   gcc -O2 -shared -fPIC -o libillumos_inotify.so illumos_inotify.c -lpthread
 */

#define _POSIX_PTHREAD_SEMANTICS 1

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/port.h>      /* PORT_SOURCE_FILE / FILE_* / struct file_obj / port_event_t */
#include <port.h>          /* port_create / port_associate / port_get ... 的声明 */
#include <limits.h>

/* ---------------------------------------------------------------------------
 * inotify 常量与结构（illumos 无 sys/inotify.h，此处按 Linux ABI 自定义）
 * ------------------------------------------------------------------------ */
#define IN_ACCESS        0x00000001u
#define IN_MODIFY        0x00000002u
#define IN_ATTRIB        0x00000004u
#define IN_CLOSE_WRITE   0x00000008u
#define IN_CLOSE_NOWRITE 0x00000010u
#define IN_OPEN          0x00000020u
#define IN_MOVED_FROM    0x00000040u
#define IN_MOVED_TO      0x00000080u
#define IN_CREATE        0x00000100u
#define IN_DELETE        0x00000200u
#define IN_DELETE_SELF   0x00000400u
#define IN_MOVE_SELF     0x00000800u
#define IN_Q_OVERFLOW    0x00004000u
#define IN_IGNORED       0x00008000u
#define IN_ISDIR         0x40000000u

struct inotify_event {
    int      wd;
    uint32_t mask;
    uint32_t cookie;
    uint32_t len;
    char     name[];
};

#ifndef NAME_MAX
#define NAME_MAX 255
#endif

#define MAX_WATCH     256          /* 每个实例最大 watch 数 */
#define MAX_FILES     512          /* 每个目录最多做文件级关联的数量 */
#define EVENT_COOKIE  0x1A2B       /* MOVED_FROM/TO 配对的 cookie 基值 */

#ifdef ILLUMOS_INOTIFY_DEBUG
#define DBG(...) do { fprintf(stderr, "[inotify] " __VA_ARGS__); } while (0)
#else
#define DBG(...) do { } while (0)
#endif

struct entry {
    char   name[NAME_MAX + 1];
    int    isdir;
    long   size;
    time_t mtime;
};

struct watch {
    int   used;
    int   wd;
    int   isdir;
    char  path[PATH_MAX];
    char *fo_name;              /* 目录路径；portfs 长期持有该指针 */
    struct file_obj fo;         /* 必须长期存活 */
    struct entry   *ents;
    int             nents;
    /* 文件级关联（仅目录监视时使用） */
    struct file_obj *ffo;
    char           **fname;
    char           **fbase;     /* basename，用于事件里的 name */
    int              nffo;
};

struct inst {
    int              port;
    int              wfd;       /* socketpair 写端 */
    int              rfd;       /* socketpair 读端 = 对外的 inotify fd */
    pthread_t        tid;
    pthread_mutex_t  lock;
    int              stop;
    int              overflow;
    struct watch     w[MAX_WATCH];
    int              nextwd;
};

/* fd -> inst 注册表 */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct inst    *g_inst[1024];

static struct inst *inst_of(int fd)
{
    struct inst *r = NULL;
    int i;
    if (fd < 0 || fd >= (int)(sizeof(g_inst) / sizeof(g_inst[0]))) return NULL;
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < (int)(sizeof(g_inst) / sizeof(g_inst[0])); i++) {
        if (g_inst[i] && g_inst[i]->rfd == fd) { r = g_inst[i]; break; }
    }
    pthread_mutex_unlock(&g_lock);
    return r;
}

static void inst_register(struct inst *in)
{
    int i, slot = -1;
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < (int)(sizeof(g_inst) / sizeof(g_inst[0])); i++) {
        if (g_inst[i] && g_inst[i]->rfd == in->rfd) {
            /* fd 被复用：停掉旧实例 */
            g_inst[i]->stop = 1;
            g_inst[i] = NULL;
            slot = i;
            break;
        }
        if (!g_inst[i] && slot < 0) slot = i;
    }
    if (slot >= 0) g_inst[slot] = in;
    pthread_mutex_unlock(&g_lock);
}

/* ---------------------------------------------------------------------------
 * 事件投递：把一条 struct inotify_event 写进 socketpair
 * ------------------------------------------------------------------------ */
static void emit(struct inst *in, int wd, uint32_t mask, uint32_t cookie,
                 const char *name, int isdir)
{
    char buf[sizeof(struct inotify_event) + NAME_MAX + 8];
    struct inotify_event *e = (struct inotify_event *)buf;
    size_t nl = 0, total;
    ssize_t n;

    memset(buf, 0, sizeof(buf));
    e->wd     = wd;
    e->mask   = isdir ? (mask | IN_ISDIR) : mask;
    e->cookie = cookie;

    if (name && *name) {
        size_t l = strlen(name) + 1;
        nl = (l + 3u) & ~((size_t)3);      /* 4 字节对齐 */
        if (nl > NAME_MAX + 8) nl = NAME_MAX + 8;
        memcpy(e->name, name, l);
    }
    e->len = (uint32_t)nl;
    total = sizeof(struct inotify_event) + nl;

    /*
     * 用 write() 而不是 send(MSG_NOSIGNAL)：illumos 的 socket.h 不保证提供
     * MSG_NOSIGNAL；SIGPIPE 已由 worker 线程用 pthread_sigmask 屏蔽，
     * 因此读端关闭时这里只会拿到 EPIPE，不会杀掉整个 .NET 进程。
     */
    n = write(in->wfd, buf, total);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            in->overflow = 1;              /* 队列满，稍后报 IN_Q_OVERFLOW */
        } else if (errno == EPIPE || errno == ECONNRESET) {
            in->stop = 1;                  /* 读端已关闭，实例作废 */
        }
    }
    DBG("emit wd=%d mask=0x%x name=%s\n", wd, e->mask, name ? name : "");
}

static void emit_overflow(struct inst *in)
{
    int i;
    for (i = 0; i < MAX_WATCH; i++) {
        if (in->w[i].used) {
            emit(in, in->w[i].wd, IN_Q_OVERFLOW, 0, NULL, 0);
        }
    }
    in->overflow = 0;
}

/* ---------------------------------------------------------------------------
 * 目录扫描与快照比对
 * ------------------------------------------------------------------------ */
static int cmpent(const void *a, const void *b)
{
    return strcmp(((const struct entry *)a)->name,
                  ((const struct entry *)b)->name);
}

static int scan_dir(const char *path, struct entry **out)
{
    DIR *d;
    struct dirent *de;
    struct entry *e;
    int n = 0, cap = 32;

    *out = NULL;
    d = opendir(path);
    if (!d) return -1;

    e = (struct entry *)calloc((size_t)cap, sizeof(*e));
    if (!e) { closedir(d); return -1; }

    while ((de = readdir(d)) != NULL) {
        char full[PATH_MAX + NAME_MAX + 2];
        struct stat st;
        struct entry *t;

        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        if (n == cap) {
            struct entry *ne;
            cap *= 2;
            ne = (struct entry *)realloc(e, (size_t)cap * sizeof(*e));
            if (!ne) { free(e); closedir(d); return -1; }
            e = ne;
        }
        t = &e[n];
        memset(t, 0, sizeof(*t));
        strncpy(t->name, de->d_name, NAME_MAX);
        t->name[NAME_MAX] = '\0';

        snprintf(full, sizeof(full), "%s/%s", path, de->d_name);
        if (lstat(full, &st) == 0) {
            t->isdir = S_ISDIR(st.st_mode) ? 1 : 0;
            t->size  = (long)st.st_size;
            t->mtime = st.st_mtime;
        }
        n++;
    }
    closedir(d);
    qsort(e, (size_t)n, sizeof(*e), cmpent);
    *out = e;
    return n;
}

/* 释放文件级关联 */
static void free_files(struct inst *in, struct watch *w)
{
    int j;
    for (j = 0; j < w->nffo; j++) {
        port_dissociate(in->port, PORT_SOURCE_FILE, (uintptr_t)&w->ffo[j]);
        free(w->fname[j]);
        free(w->fbase[j]);
    }
    free(w->ffo);   w->ffo = NULL;
    free(w->fname); w->fname = NULL;
    free(w->fbase); w->fbase = NULL;
    w->nffo = 0;
}

/* 对目录内普通文件做 port_associate，用于感知内容修改 */
static void assoc_files(struct inst *in, struct watch *w,
                        struct entry *ents, int nents)
{
    int i, k = 0, cap;

    free_files(in, w);
    if (!ents || nents <= 0) return;

    cap = nents < MAX_FILES ? nents : MAX_FILES;
    w->ffo   = (struct file_obj *)calloc((size_t)cap, sizeof(struct file_obj));
    w->fname = (char **)calloc((size_t)cap, sizeof(char *));
    w->fbase = (char **)calloc((size_t)cap, sizeof(char *));
    if (!w->ffo || !w->fname || !w->fbase) {
        free_files(in, w);
        return;
    }

    for (i = 0; i < nents && k < cap; i++) {
        char full[PATH_MAX + NAME_MAX + 2];
        struct stat st;

        if (ents[i].isdir) continue;
        snprintf(full, sizeof(full), "%s/%s", w->path, ents[i].name);
        if (stat(full, &st) != 0) continue;

        w->fname[k] = strdup(full);
        w->fbase[k] = strdup(ents[i].name);
        if (!w->fname[k] || !w->fbase[k]) {
            free(w->fname[k]); w->fname[k] = NULL;
            free(w->fbase[k]); w->fbase[k] = NULL;
            break;
        }
        w->ffo[k].fo_atime = st.st_atim;
        w->ffo[k].fo_mtime = st.st_mtim;
        w->ffo[k].fo_ctime = st.st_ctim;
        w->ffo[k].fo_name  = w->fname[k];

        if (port_associate(in->port, PORT_SOURCE_FILE,
                           (uintptr_t)&w->ffo[k], FILE_MODIFIED, NULL) == 0) {
            k++;
        } else {
            free(w->fname[k]); w->fname[k] = NULL;
            free(w->fbase[k]); w->fbase[k] = NULL;
        }
    }
    w->nffo = k;
    DBG("assoc_files %s: %d 个文件\n", w->path, k);
}

/* 关联目录本身，拿 name 级变化 */
static int assoc_dir(struct inst *in, struct watch *w)
{
    struct stat st;

    if (stat(w->path, &st) != 0) return -1;
    if (!w->fo_name) {
        w->fo_name = strdup(w->path);
        if (!w->fo_name) return -1;
    }
    w->fo.fo_atime = st.st_atim;
    w->fo.fo_mtime = st.st_mtim;
    w->fo.fo_ctime = st.st_ctim;
    w->fo.fo_name  = w->fo_name;

    /*
     * 只能传可过滤的位（FILE_ACCESS / FILE_MODIFIED / FILE_ATTRIB / FILE_TRUNC）。
     * FILE_DELETE / FILE_RENAME_TO / FILE_RENAME_FROM / UNMOUNTED / MOUNTEDOVER
     * 是**异常事件**，port_associate 手册明确说 "cannot be filtered" ——
     * 把它们 OR 进 events 会直接 EINVAL（实测 errno=22）。
     * 不传也会在发生时自动投递，所以目录的增/删/改名靠 mtime 变化
     * （FILE_MODIFIED）触发，再由快照比对还原。
     */
    {
        int r = port_associate(in->port, PORT_SOURCE_FILE, (uintptr_t)&w->fo,
                               FILE_MODIFIED | FILE_ATTRIB, NULL);
        DBG("assoc_dir %s -> %d%s%s\n", w->path, r,
            r ? " errno=" : "", r ? strerror(errno) : "");
        return r;
    }
}

/* 目录快照比对 → 生成 CREATE/DELETE/MOVED/MODIFY 事件 */
static void diff_dir(struct inst *in, struct watch *w)
{
    struct entry *neu = NULL;
    int nn, i, j, *uo = NULL, *un = NULL;
    uint32_t cookie = (uint32_t)(EVENT_COOKIE + w->wd);

    nn = scan_dir(w->path, &neu);
    if (nn < 0) return;

    uo = (int *)calloc((size_t)(w->nents > 0 ? w->nents : 1), sizeof(int));
    un = (int *)calloc((size_t)(nn > 0 ? nn : 1), sizeof(int));
    if (!uo || !un) { free(uo); free(un); free(neu); return; }

    /* 1) 同名条目：比对内容修改 */
    for (i = 0; i < w->nents; i++) {
        for (j = 0; j < nn; j++) {
            if (uo[i] || un[j]) continue;
            if (strcmp(w->ents[i].name, neu[j].name)) continue;
            uo[i] = un[j] = 1;
            if (!neu[j].isdir &&
                (neu[j].size != w->ents[i].size ||
                 neu[j].mtime != w->ents[i].mtime)) {
                emit(in, w->wd, IN_MODIFY, 0, neu[j].name, 0);
            }
            break;
        }
    }

    /* 2) 消失的 / 新增的 —— 先尝试配对成 rename */
    for (i = 0; i < w->nents; i++) {
        if (uo[i]) continue;
        for (j = 0; j < nn; j++) {
            if (un[j]) continue;
            if (w->ents[i].isdir != neu[j].isdir) continue;
            /* 文件：大小与 mtime 都一致才认定为同一次 rename */
            if (!w->ents[i].isdir &&
                (w->ents[i].size != neu[j].size ||
                 w->ents[i].mtime != neu[j].mtime)) continue;
            uo[i] = un[j] = 1;
            emit(in, w->wd, IN_MOVED_FROM, cookie, w->ents[i].name,
                 w->ents[i].isdir);
            emit(in, w->wd, IN_MOVED_TO,   cookie, neu[j].name, neu[j].isdir);
            break;
        }
    }

    /* 3) 剩下的消失项 = 删除 */
    for (i = 0; i < w->nents; i++) {
        if (uo[i]) continue;
        uo[i] = 1;
        emit(in, w->wd, IN_DELETE, 0, w->ents[i].name, w->ents[i].isdir);
    }

    /* 4) 剩下的新增项 = 创建 */
    for (j = 0; j < nn; j++) {
        if (un[j]) continue;
        un[j] = 1;
        emit(in, w->wd, IN_CREATE, 0, neu[j].name, neu[j].isdir);
    }

    free(uo);
    free(un);

    /* 更新快照 */
    free(w->ents);
    w->ents  = neu;
    w->nents = nn;

    /* 文件级关联需要跟着目录内容变化重建 */
    assoc_files(in, w, w->ents, w->nents);
}

/* ---------------------------------------------------------------------------
 * 事件分发
 * ------------------------------------------------------------------------ */
static void handle_object(struct inst *in, void *obj)
{
    int i, j;

    for (i = 0; i < MAX_WATCH; i++) {
        struct watch *w = &in->w[i];
        if (!w->used) continue;

        if (w->isdir && obj == (void *)&w->fo) {
            DBG("目录事件: %s\n", w->path);
            diff_dir(in, w);
            assoc_dir(in, w);          /* 取走后关联已解除，必须重新关联 */
            return;
        }

        for (j = 0; j < w->nffo; j++) {
            struct stat st;

            if (obj != (void *)&w->ffo[j]) continue;

            if (w->isdir) {
                emit(in, w->wd, IN_MODIFY, 0, w->fbase[j], 0);
            } else {
                emit(in, w->wd, IN_MODIFY, 0, NULL, 0);
            }

            if (stat(w->fname[j], &st) == 0) {
                w->ffo[j].fo_atime = st.st_atim;
                w->ffo[j].fo_mtime = st.st_mtim;
                w->ffo[j].fo_ctime = st.st_ctim;
                port_associate(in->port, PORT_SOURCE_FILE,
                               (uintptr_t)&w->ffo[j], FILE_MODIFIED, NULL);

                /*
                 * 关键：同步目录快照里这个文件的 size/mtime。
                 * 目录快照只在"目录级事件"时重建，而内容修改只触发文件级事件；
                 * 不同步的话，随后的 rename 会因为 size/mtime 对不上而
                 * 退化成 DELETE + CREATE（丢失 Renamed 语义）。
                 */
                if (w->isdir) {
                    int k;
                    for (k = 0; k < w->nents; k++) {
                        if (!strcmp(w->ents[k].name, w->fbase[j])) {
                            w->ents[k].size  = (long)st.st_size;
                            w->ents[k].mtime = st.st_mtime;
                            break;
                        }
                    }
                }
            }
            return;
        }
    }
    DBG("未知对象 %p\n", obj);
}

static void *worker(void *arg)
{
    struct inst *in = (struct inst *)arg;
    sigset_t set;
    int bad = 0;

    /* 关键：屏蔽 SIGPIPE。读端被 .NET 关闭后 send() 会返回 EPIPE 而不是杀进程 */
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &set, NULL);

    for (;;) {
        port_event_t pe;
        timespec_t   ts;
        int r, e, stop;

        ts.tv_sec  = 0;
        ts.tv_nsec = 200 * 1000 * 1000;      /* 200ms，用于定期检查 stop */

        errno = 0;
        r = port_get(in->port, &pe, &ts);
        e = errno;

        if (r != 0) {
            /*
             * 注意 illumos 的 port_get 在超时时返回 -1 **且不设置 errno**
             * （实测 errno 保持 0）。所以必须把 errno==0 也当成"无事件"，
             * 否则连续超时会被误判为故障，worker 空闲一段时间后自己退出。
             */
            if (e == 0 || e == ETIME || e == EINTR) {
                stop = 0;
                pthread_mutex_lock(&in->lock);
                stop = in->stop;
                pthread_mutex_unlock(&in->lock);
                if (stop) break;
                continue;
            }
            /*
             * 真正的错误也不要立刻终止 —— 否则一次偶发失败会让整个
             * watcher 永久静默。累计到一定次数才放弃。
             */
            DBG("port_get r=%d errno=%d (%s)\n", r, e, strerror(e));
            if (++bad > 50) break;
            usleep(10000);
            continue;
        }
        bad = 0;

        pthread_mutex_lock(&in->lock);
        if (in->stop) { pthread_mutex_unlock(&in->lock); break; }

        if (pe.portev_source == PORT_SOURCE_FILE) {
            handle_object(in, (void *)pe.portev_object);
        }
        if (in->overflow) emit_overflow(in);
        pthread_mutex_unlock(&in->lock);
    }
    return NULL;
}

/* ---------------------------------------------------------------------------
 * 对外 API
 * ------------------------------------------------------------------------ */
int inotify_init1(int flags)
{
    struct inst *in;
    int sv[2];
    int fl;

    (void)flags;

    in = (struct inst *)calloc(1, sizeof(*in));
    if (!in) { errno = ENOMEM; return -1; }

    in->port = port_create();
    if (in->port < 0) { free(in); return -1; }

    /* 用 socketpair 而不是 pipe：send(MSG_NOSIGNAL) 可彻底避免 SIGPIPE */
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        close(in->port); free(in); return -1;
    }
    in->rfd = sv[0];
    in->wfd = sv[1];

    fl = fcntl(in->wfd, F_GETFL, 0);
    fcntl(in->wfd, F_SETFL, fl | O_NONBLOCK);
    fcntl(in->rfd, F_SETFD, FD_CLOEXEC);
    fcntl(in->wfd, F_SETFD, FD_CLOEXEC);

    pthread_mutex_init(&in->lock, NULL);
    in->nextwd = 1;

    if (pthread_create(&in->tid, NULL, worker, in) != 0) {
        close(in->port); close(in->rfd); close(in->wfd);
        pthread_mutex_destroy(&in->lock);
        free(in);
        errno = EAGAIN;
        return -1;
    }

    inst_register(in);
    DBG("inotify_init1 -> fd=%d port=%d\n", in->rfd, in->port);
    return in->rfd;
}

int inotify_add_watch(int fd, const char *path, uint32_t mask)
{
    struct inst *in = inst_of(fd);
    struct stat st;
    int i, slot = -1, wd;
    struct watch *w;

    (void)mask;
    if (!in) { errno = EBADF; return -1; }
    if (!path || stat(path, &st) != 0) return -1;

    pthread_mutex_lock(&in->lock);

    /* 同一路径重复添加：返回原 wd（与 Linux 行为一致） */
    for (i = 0; i < MAX_WATCH; i++) {
        if (in->w[i].used && !strcmp(in->w[i].path, path)) {
            wd = in->w[i].wd;
            pthread_mutex_unlock(&in->lock);
            return wd;
        }
        if (!in->w[i].used && slot < 0) slot = i;
    }
    if (slot < 0) { pthread_mutex_unlock(&in->lock); errno = ENOSPC; return -1; }

    w = &in->w[slot];
    memset(w, 0, sizeof(*w));
    w->used  = 1;
    w->wd    = in->nextwd++;
    w->isdir = S_ISDIR(st.st_mode) ? 1 : 0;
    strncpy(w->path, path, PATH_MAX - 1);

    if (w->isdir) {
        if (assoc_dir(in, w) != 0) goto fail;
        w->nents = scan_dir(w->path, &w->ents);
        if (w->nents < 0) { w->nents = 0; w->ents = NULL; }
        assoc_files(in, w, w->ents, w->nents);
    } else {
        /* 单文件监视：Linux 语义下事件不带 name */
        char *full = strdup(path);

        if (!full) goto fail;
        w->ffo   = (struct file_obj *)calloc(1, sizeof(struct file_obj));
        w->fname = (char **)calloc(1, sizeof(char *));
        w->fbase = (char **)calloc(1, sizeof(char *));
        if (!w->ffo || !w->fname || !w->fbase) { free(full); goto fail; }
        w->fname[0] = full;                 /* 交给 fail 路径统一释放 */
        w->fbase[0] = strdup(path);
        if (!w->fbase[0]) goto fail;
        w->ffo[0].fo_atime = st.st_atim;
        w->ffo[0].fo_mtime = st.st_mtim;
        w->ffo[0].fo_ctime = st.st_ctim;
        w->ffo[0].fo_name  = full;
        if (port_associate(in->port, PORT_SOURCE_FILE, (uintptr_t)&w->ffo[0],
                           FILE_MODIFIED | FILE_ATTRIB, NULL) != 0) {
            goto fail;
        }
        w->nffo = 1;
    }

    wd = w->wd;
    pthread_mutex_unlock(&in->lock);
    DBG("add_watch %s -> wd=%d (%s)\n", path, wd, w->isdir ? "dir" : "file");
    return wd;

fail:
    {
        /* 保留真实失败原因，别被清理动作掩盖 */
        int saved = errno;

        if (w->isdir) {
            port_dissociate(in->port, PORT_SOURCE_FILE, (uintptr_t)&w->fo);
        }
        free_files(in, w);
        free(w->ents);
        free(w->fo_name);
        memset(w, 0, sizeof(*w));
        pthread_mutex_unlock(&in->lock);
        errno = saved ? saved : EINVAL;
        DBG("add_watch %s 失败: %s\n", path, strerror(errno));
        return -1;
    }
}

int inotify_rm_watch(int fd, int wd)
{
    struct inst *in = inst_of(fd);
    int i;

    if (!in) { errno = EBADF; return -1; }

    pthread_mutex_lock(&in->lock);
    for (i = 0; i < MAX_WATCH; i++) {
        struct watch *w = &in->w[i];
        if (!w->used || w->wd != wd) continue;

        if (w->isdir) {
            port_dissociate(in->port, PORT_SOURCE_FILE, (uintptr_t)&w->fo);
        }
        free_files(in, w);
        free(w->ents);   w->ents = NULL;
        free(w->fo_name); w->fo_name = NULL;
        w->used = 0;

        /* Linux 在 rm_watch 后会投递 IN_IGNORED */
        emit(in, wd, IN_IGNORED, 0, NULL, 0);
        pthread_mutex_unlock(&in->lock);
        return 0;
    }
    pthread_mutex_unlock(&in->lock);
    errno = EINVAL;
    return -1;
}
ILLUMOS_INOTIFY_C_EOF

    cat > "$FSW_DIR/pal_shim.c" <<'PAL_SHIM_C_EOF'
/*
 * pal_shim.c — .NET PAL 垫片：把 libSystem.Native 里被编成 ENOTSUP 桩的
 *              FileSystemWatcher 原生入口重定向到用户态 inotify
 * =============================================================================
 *
 * 原理
 * ----
 * .NET 的 P/Invoke 解析流程是：
 *       dlopen("libSystem.Native.so")  →  dlsym(handle, "SystemNative_INotifyInit")
 * 而 dlsym(handle, sym) 会沿该 handle 的 **DT_NEEDED 依赖链**继续查找。
 *
 * 所以只要造一个同名的 libSystem.Native.so（本文件），它：
 *   1) 自己定义那 3 个 inotify 符号          → 覆盖掉原库里的 ENOTSUP 桩
 *   2) DT_NEEDED 指向改名的原库 libSNative.so → 其余 200+ 符号沿依赖链透传
 * 就能在不重建 SDK 的前提下换掉这段实现。
 *
 * 前提（install 脚本负责）
 * ------------------------
 *   - 原 libSystem.Native.so 复制为 libSNative.so 并把 SONAME 改成 libSNative.so
 *     （不改 SONAME 的话 ld 会报 "recording name conflict" 直接拒绝链接）
 *   - 本垫片的 SONAME 保持 libSystem.Native.so，DT_RUNPATH 用 $ORIGIN，
 *     保证同一目录下能找到 libSNative.so
 *
 * 编译
 * ----
 *   gcc -O2 -shared -fPIC -o libSystem.Native.so pal_shim.c \
 *       ./libSNative.so \
 *       -Wl,-soname,libSystem.Native.so \
 *       -Wl,-z,origin -Wl,-rpath,'$ORIGIN' \
 *       ./libillumos_inotify.so
 */

#include <stdint.h>

/* 用户态 inotify 实现（libillumos_inotify.so） */
extern int inotify_init1(int flags);
extern int inotify_add_watch(int fd, const char *path, uint32_t mask);
extern int inotify_rm_watch(int fd, int wd);

/* 与 dotnet/runtime 的 pal_io.h 保持一致 */
#ifndef O_CLOEXEC
#define O_CLOEXEC 0x80000
#endif

intptr_t SystemNative_INotifyInit(void)
{
    return (intptr_t)inotify_init1(O_CLOEXEC);
}

int32_t SystemNative_INotifyAddWatch(intptr_t fd, const char *pathName, uint32_t mask)
{
    if (fd < 0 || pathName == 0) return -1;
    return (int32_t)inotify_add_watch((int)fd, pathName, mask);
}

int32_t SystemNative_INotifyRemoveWatch(intptr_t fd, int32_t wd)
{
    if (fd < 0) return -1;
    return (int32_t)inotify_rm_watch((int)fd, (int)wd);
}
PAL_SHIM_C_EOF

    cat > "$FSW_DIR/fsw_selftest.c" <<'FSW_SELFTEST_C_EOF'
/*
 * fsw_selftest.c — 垫片安装后的 C 层自检
 *   dlopen 垫片 -> dlsym 三个覆盖符号 + 一个透传符号 -> 实调 -> 校验
 * 不依赖 .NET 工具链，避免把 SDK 自身的问题误判成垫片故障。
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>

int main(int argc, char **argv)
{
    void *h;
    long (*init1)(void);
    void *(*m)(unsigned long);
    long fd;

    if (argc < 2) { printf("SELFTEST FAIL 用法: fsw_selftest <垫片路径>\n"); return 2; }

    h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("SELFTEST FAIL dlopen: %s\n", dlerror()); return 1; }

    /* 1) 覆盖符号必须在垫片里 */
    init1 = (long (*)(void))dlsym(h, "SystemNative_INotifyInit");
    if (!init1) { printf("SELFTEST FAIL 找不到 SystemNative_INotifyInit\n"); return 1; }

    fd = init1();
    if (fd < 0) { printf("SELFTEST FAIL InotifyInit 返回 %ld\n", fd); return 1; }

    /* 2) 透传符号必须经依赖链从原库解析到 */
    m = (void *(*)(unsigned long))dlsym(h, "SystemNative_Malloc");
    if (!m || !m(32)) { printf("SELFTEST FAIL 透传符号 SystemNative_Malloc 异常\n"); return 1; }

    /* 3) 继续验证 add_watch 真的能挂上（说明 portfs 可用） */
    {
        int (*addw)(long, const char *, unsigned int);
        addw = (int (*)(long, const char *, unsigned int))dlsym(h, "SystemNative_INotifyAddWatch");
        if (!addw) { printf("SELFTEST FAIL 找不到 SystemNative_INotifyAddWatch\n"); return 1; }
    }

    printf("SELFTEST OK fd=%ld\n", fd);
    return 0;
}
FSW_SELFTEST_C_EOF

    # --- 3.5a) 编译用户态 inotify ---
    # illumos 的 socketpair 在 libsocket 里，不显式链接会 undefined symbol
    if gcc -O2 -shared -fPIC -o "$FSW_DIR/libillumos_inotify.so"            "$FSW_DIR/illumos_inotify.c"            -lpthread -lsocket -lnsl -Wl,-soname,libillumos_inotify.so            >"$FSW_DIR/build.log" 2>&1; then
      c_ok "  libillumos_inotify.so 编译成功（$(stat -c%s "$FSW_DIR/libillumos_inotify.so") 字节）"

      if gcc -O2 -o "$FSW_DIR/fsw_selftest" "$FSW_DIR/fsw_selftest.c"              -lsocket -lnsl >"$FSW_DIR/selftest-build.log" 2>&1; then

        FSW_OK=0
        FSW_SKIP=0

        # 每个共享框架目录都处理（通常只有 Microsoft.NETCore.App 一个）
        for FD in "$PREFIX"/shared/*/*/libSystem.Native.so; do
          [ -f "$FD" ] || { FSW_SKIP=1; continue; }

          FDIR="$(dirname "$FD")"
          REAL="$FDIR/libSNative.so"
          INOT="$FDIR/libillumos_inotify.so"
          TAG="$(basename "$FDIR")"
          ORIG="$ORIG_STORE/$TAG.libSystem.Native.so"

          # 首次安装：先把原始库留一份永久备份
          if [ ! -s "$ORIG" ] && [ ! -s "$REAL" ]; then
            cp -p "$FD" "$ORIG"
            c_info "  原始库已备份到 $ORIG"
          fi

          # 幂等：已装过就先清干净，重新构建
          if [ -s "$REAL" ]; then
            c_info "  检测到既有垫片，先还原再重建"
            [ -s "$ORIG" ] && cp -f "$ORIG" "$FD" || cp -f "$REAL" "$FD"
            rm -f "$REAL" "$INOT"
          fi

          # 复制出真库并改 SONAME（必须等长或更短）
          cp -f "$FD" "$REAL"
          if "$PY" - "$REAL" <<'SONAME_PY_EOF'
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
old = b"libSystem.Native.so\x00"
new = b"libSNative.so\x00"
i = d.find(old)
if i < 0:
    print("SONAME 已是 libSNative.so，跳过")
else:
    d[i:i + len(old)] = new + b"\x00" * (len(old) - len(new))
    open(p, "wb").write(bytes(d))
    print("SONAME 已改写为 libSNative.so")
SONAME_PY_EOF
          then :; else c_warn "  改 SONAME 失败"; fi

          # 编垫片：SONAME 保持原名，DT_NEEDED 指向真库，$ORIGIN 定位同目录
          if gcc -O2 -shared -fPIC -o "$FD" "$FSW_DIR/pal_shim.c" "$REAL"                  -L"$FSW_DIR" -lillumos_inotify                  -Wl,-soname,libSystem.Native.so                  -Wl,-z,origin -Wl,-rpath,'$ORIGIN'                  >>"$FSW_DIR/build.log" 2>&1; then
            cp -f "$FSW_DIR/libillumos_inotify.so" "$INOT"

            if OUT="$("$FSW_DIR/fsw_selftest" "$FD" 2>&1)" &&                printf '%s' "$OUT" | grep -q "SELFTEST OK"; then
              c_ok "  垫片就位并自检通过（$TAG）"
              FSW_OK=1
            else
              c_warn "  垫片自检失败，回滚：$OUT"
              [ -s "$ORIG" ] && cp -f "$ORIG" "$FD" || true
              rm -f "$REAL" "$INOT"
            fi
          else
            c_warn "  垫片编译失败，回滚"
            sed 's/^/    /' "$FSW_DIR/build.log" | tail -n 5 >&2 || true
            [ -s "$ORIG" ] && cp -f "$ORIG" "$FD" || true
            rm -f "$REAL" "$INOT"
          fi
        done

        [ "$FSW_SKIP" = "1" ] && c_warn "  没找到 libSystem.Native.so，跳过"
        if [ "$FSW_OK" = "1" ]; then
          c_ok "FileSystemWatcher 已可用（portfs 后端，非轮询）"
        fi
      else
        c_warn "  自检程序编译失败，跳过垫片安装"
        sed 's/^/    /' "$FSW_DIR/selftest-build.log" | tail -n 5 >&2 || true
      fi
    else
      c_warn "  libillumos_inotify.so 编译失败，跳过垫片安装"
      sed 's/^/    /' "$FSW_DIR/build.log" | tail -n 10 >&2 || true
    fi
    rm -rf "$FSW_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# 4) 环境变量
# ---------------------------------------------------------------------------
if [ "$DO_PROFILE" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    c_ok "[dry-run] 将写 /etc/profile.d/illumos-dotnet.sh"
  else
    PROF=/etc/profile.d/illumos-dotnet.sh
    c_info "写 $PROF"
    cat > "$PROF" <<EOF
# .NET SDK (illumos 适配版) —— 由 install-illumos.sh 生成
export DOTNET_ROOT=$PREFIX
case ":\$PATH:" in
  *":$PREFIX:"*) : ;;
  *) PATH="$PREFIX:\$PATH"; export PATH ;;
esac

# 证书：illumos 上 /etc/ssl/certs 默认不存在，且系统库缺微软签名链的老根
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs

# 关键：从官方替换进来的程序集带 R2R 预编译代码，illumos 加载会 core dump
export DOTNET_ReadyToRun=0

# 可选：静音 "MSBuild server unavailable ... Falling back to an in-process build"
# export DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1
EOF
    chmod 0644 "$PROF"
    ln -sf "$PREFIX/dotnet" /usr/bin/dotnet 2>/dev/null \
      && c_ok "/usr/bin/dotnet -> $PREFIX/dotnet" || true
    c_ok "已写入（新登录 shell 自动生效）"
  fi
fi

# ---------------------------------------------------------------------------
# 5) 自检
# ---------------------------------------------------------------------------
echo
c_info "===== 自检 ====="
export DOTNET_ROOT="$PREFIX"
export PATH="$PREFIX:$PATH"
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs
export DOTNET_ReadyToRun=0
export DOTNET_NOLOGO=1

if [ "$DRY" = "1" ]; then
  c_info "[dry-run] 结束，未做任何改动"
  exit 0
fi

if "$PREFIX/dotnet" --version >/tmp/dnv.txt 2>&1; then
  c_ok "dotnet --version => $(cat /tmp/dnv.txt)"
else
  c_warn "dotnet --version 失败:"
  sed 's/^/    /' /tmp/dnv.txt >&2 || true
fi
rm -f /tmp/dnv.txt

MAJORV="$("$PREFIX/dotnet" --version 2>/dev/null | cut -d. -f1)"
case "$MAJORV" in ''|*[!0-9]*) MAJORV="${MJR:-11}" ;; esac
SMOKE_TFM="net${MAJORV}.0"
c_info "冒烟测试 TFM: $SMOKE_TFM"

SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-smoke.XXXXXX")"
cat > "$SMOKE/smoke.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$SMOKE_TFM</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NETCore.Platforms" Version="7.0.0" />
  </ItemGroup>
</Project>
EOF
echo 'class P { static void Main() { System.Console.WriteLine("smoke ok"); } }' > "$SMOKE/Program.cs"

c_info "联网 restore 冒烟测试 ..."
if ( cd "$SMOKE" && timeout 180 "$PREFIX/dotnet" restore \
       -p:NETCoreAppMaximumVersion="${MAJORV}.0" -v minimal >/tmp/smoke.log 2>&1 ); then
  c_ok "在线 restore 成功 —— TLS + 证书 + dll 全部正常"
else
  c_warn "在线 restore 失败，日志末尾:"
  tail -n 15 /tmp/smoke.log 2>/dev/null | sed 's/^/    /' >&2 || true
  c_warn "常见原因：网络不通（需代理时设 https_proxy）、或证书/dll 未生效"
fi
rm -rf "$SMOKE" /tmp/smoke.log

echo
c_info "===== 完成 ====="
c_info "安装前缀 : $PREFIX"
c_info "生效方式 : 重新登录，或 source /etc/profile.d/illumos-dotnet.sh"
echo
echo "    export DOTNET_ROOT=$PREFIX PATH=$PREFIX:\$PATH DOTNET_ReadyToRun=0"
echo "    dotnet --info"
