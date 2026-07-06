#!/usr/bin/env bash
#
# s3-bucket-key-check.sh
# ======================
# 現在の IAM 権限で確認可能な S3 バケットの一覧を表示し、各バケットに含まれる
# ディレクトリ(prefix)とファイル(オブジェクト)を階層インデント付きの
# 「極めてわかりやすい」リスト形式で表示するスクリプトです。
#
# あわせて、Excel でそのまま読み込める CSV ファイル（UTF-8 BOM 付き / CRLF）
# への出力機能を持ちます。
#
# 何をするか:
#   1. 実行開始時に AWS 認証済みか（aws sts get-caller-identity）を確認する。
#      未認証なら「aws login --remote で認証してください」と警告して終了する。
#   2. S3 の操作権限（s3:ListAllMyBuckets 等）があるか確認する。
#      権限が無い場合（スイッチロール中など）:
#        * 既定               : スイッチバックするよう警告して終了する。
#        * --auto-switch-back : 別チーム提供の専用シェルを source して
#                               自動でスイッチバックし、再確認して続行する。
#   3. バケット一覧を取得し、各バケットの中身をツリー状のリストで表示する。
#   4. 同じ内容を CSV へ出力する（--no-csv で抑止可能）。
#
# 認証 / 権限について:
#   - 本スクリプトは読み取り専用（list-buckets / get-bucket-location /
#     list-objects-v2）であり、S3 への書き込みは一切行いません。
#   - 必要な IAM 権限: s3:ListAllMyBuckets, s3:GetBucketLocation, s3:ListBucket
#   - CodeCommit の操作は行わないため、スイッチロールは不要です。
#
# 依存: bash, aws (CLI v2)
# 共通部品: common.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
BUCKET_FILTER=""            # 対象バケット名（カンマ区切りで複数可）。空なら全バケット
PREFIX=""                   # バケット内のディレクトリ(prefix)。空ならバケット直下から全階層
MAX_KEYS="50"               # 各バケットで表示する最新オブジェクト数（0 = 無制限）
BUCKETS_ONLY="false"        # true ならバケット一覧のみ（中身は取得しない）
OUTPUT_CSV=""               # CSV 出力先パス。空なら既定名で出力
NO_CSV="false"              # true なら CSV 出力を行わない

# --- ファイル内容の表示 / 出力（parquet / gz）関連 ---
# true なら parquet / gz ファイルの内容をダウンロードして画面表示 + ファイル出力する
SHOW_CONTENT="false"
# 内容出力先ディレクトリ。空なら既定名（./s3_content_<日時>）を使う
CONTENT_DIR=""
# 内容取得の対象とするオブジェクトの最大サイズ（バイト）。これを超えるものはスキップ
CONTENT_MAX_BYTES="52428800"   # 50 MiB
# 画面表示・parquet 変換で扱う行数の上限（0 = 無制限）
CONTENT_MAX_ROWS="50"
# gz などテキスト内容を画面表示する際の行数上限（0 = 無制限）
CONTENT_MAX_LINES="100"

# --- 認証 / 権限（スイッチバック）関連 ---
# true なら S3 権限が無いとき警告終了せず自動でスイッチバックする
AUTO_SWITCH_BACK="false"
# 別チーム提供の「スイッチバック用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"

DEBUG="${DEBUG:-false}"
export DEBUG

# 集計用（main で更新）
TOTAL_BUCKETS=0
TOTAL_OBJECTS=0
TOTAL_BYTES=0
DENIED_BUCKETS=0

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} [オプション]

説明:
  現在の権限で確認可能な S3 バケットの一覧と、各バケット内の
  ディレクトリ/ファイルを階層リスト形式で表示します。
  あわせて Excel で読み込める CSV（UTF-8 BOM 付き / CRLF）へ出力します。

オプション:
  --bucket <name[,name...]>  対象バケットを限定する（カンマ区切りで複数指定可。
                             既定: 一覧で確認できる全バケット）
  --prefix <dir>             バケット内のディレクトリ(prefix)を指定して、その配下だけを
                             対象にする（例: logs/ や data/2026/。既定: バケット全体）
  --max-keys <n>             各バケットで表示するオブジェクト数の上限
                             （最終更新日時の新しい順に n 件。既定: 50。
                              0 を指定すると無制限に全件表示する）
  --buckets-only             バケット一覧のみ表示し、中身の取得を行わない
  --output <path>            CSV 出力先ファイルパス
                             （既定: ./s3_bucket_list_<日時>.csv）
  --no-csv                   CSV ファイル出力を行わない（画面表示のみ）
  --show-content             parquet / gz 形式のファイルをダウンロードして内容を
                             画面表示し、ファイルにも出力する
                             ・parquet: スキーマ・行数・先頭データを表形式で表示
                             ・gz     : 自動解凍して内容を表示（テキスト想定）
  --content-dir <path>       --show-content の内容出力先ディレクトリ
                             （既定: ./s3_content_<日時>）
  --content-max-bytes <n>    内容取得の対象とするオブジェクト最大サイズ(バイト)
                             （これを超えるものはスキップ。既定: 52428800 = 50MiB）
  --content-max-rows <n>     parquet の表示・変換行数の上限（既定: 50。0 = 無制限）
  --content-max-lines <n>    gz などテキスト内容の表示行数の上限（既定: 100。0 = 無制限）
  --auto-switch-back         S3 操作権限が無い場合、警告終了せず自動でスイッチバックする
                             （既定: スイッチバックするよう警告して終了）
  --switch-back-script <path>
                             自動スイッチバック時に source する専用シェルのパス
                             （別チーム提供。環境変数 SWITCH_BACK_SCRIPT でも指定可）
  --debug                    デバッグログを出力する
  -h, --help                 このヘルプを表示

認証 / 権限について:
  - 実行開始時に AWS 認証済みか（aws sts get-caller-identity）を確認します。
    未認証の場合は「aws login --remote で認証してください」と警告して終了します。
  - 本スクリプトは CodeCommit を操作しないためスイッチロールは不要ですが、
    S3 の操作権限は必要です。権限が無い場合（スイッチロール中など）:
      * 既定                : スイッチバックするよう警告して終了します。
      * --auto-switch-back  : --switch-back-script の専用シェルを source して
                              自動でスイッチバックします。

例:
  # 全バケットの中身を一覧表示し、既定名の CSV へ出力
  ./${SCRIPT_NAME}

  # 特定バケットのみ、最新 500 オブジェクトまで表示
  ./${SCRIPT_NAME} --bucket my-artifacts --max-keys 500

  # バケット内の特定ディレクトリ(prefix)配下だけを対象にする
  ./${SCRIPT_NAME} --bucket my-artifacts --prefix logs/2026/

  # parquet / gz ファイルの中身も画面表示しファイルへ出力する
  ./${SCRIPT_NAME} --bucket my-data --prefix export/ --show-content

  # 件数制限なしで全オブジェクトを表示
  ./${SCRIPT_NAME} --max-keys 0

  # バケット一覧だけ確認（中身は見ない）
  ./${SCRIPT_NAME} --buckets-only

  # S3 権限が無ければ専用シェルで自動スイッチバックして実行
  ./${SCRIPT_NAME} --auto-switch-back --switch-back-script /path/to/switch_back.sh

  # CSV 出力先を指定
  ./${SCRIPT_NAME} --output /tmp/s3_list.csv

終了コード:
  0  成功
  1  エラー（未認証 / 権限なし / API 失敗など）
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数パース
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --bucket)             BUCKET_FILTER="${2:-}"; shift 2 ;;
      --prefix)             PREFIX="${2:-}"; shift 2 ;;
      --max-keys)           MAX_KEYS="${2:-}"; shift 2 ;;
      --buckets-only)       BUCKETS_ONLY="true"; shift 1 ;;
      --output)             OUTPUT_CSV="${2:-}"; shift 2 ;;
      --no-csv)             NO_CSV="true"; shift 1 ;;
      --show-content)       SHOW_CONTENT="true"; shift 1 ;;
      --content-dir)        CONTENT_DIR="${2:-}"; shift 2 ;;
      --content-max-bytes)  CONTENT_MAX_BYTES="${2:-}"; shift 2 ;;
      --content-max-rows)   CONTENT_MAX_ROWS="${2:-}"; shift 2 ;;
      --content-max-lines)  CONTENT_MAX_LINES="${2:-}"; shift 2 ;;
      --auto-switch-back)   AUTO_SWITCH_BACK="true"; shift 1 ;;
      --switch-back-script) SWITCH_BACK_SCRIPT="${2:-}"; shift 2 ;;
      --debug)              DEBUG="true"; export DEBUG; shift 1 ;;
      -h|--help)            usage; exit 0 ;;
      *)                    usage; die "不明なオプションです: ${1}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. 入力検証
# ---------------------------------------------------------------------------
validate_inputs() {
  [[ "${MAX_KEYS}" =~ ^[0-9]+$ ]] || die "--max-keys には 0 以上の整数を指定してください: ${MAX_KEYS}"

  if [[ "${NO_CSV}" == "true" && -n "${OUTPUT_CSV}" ]]; then
    die "--no-csv と --output は同時に指定できません。"
  fi
  if [[ "${NO_CSV}" != "true" && -z "${OUTPUT_CSV}" ]]; then
    OUTPUT_CSV="./s3_bucket_list_$(date +%Y%m%d_%H%M%S).csv"
  fi

  # --- ファイル内容表示（--show-content）関連の検証 ---
  if [[ "${SHOW_CONTENT}" == "true" ]]; then
    [[ "${CONTENT_MAX_BYTES}" =~ ^[0-9]+$ ]] || die "--content-max-bytes には 0 以上の整数を指定してください: ${CONTENT_MAX_BYTES}"
    [[ "${CONTENT_MAX_ROWS}"  =~ ^[0-9]+$ ]] || die "--content-max-rows には 0 以上の整数を指定してください: ${CONTENT_MAX_ROWS}"
    [[ "${CONTENT_MAX_LINES}" =~ ^[0-9]+$ ]] || die "--content-max-lines には 0 以上の整数を指定してください: ${CONTENT_MAX_LINES}"
    if [[ "${BUCKETS_ONLY}" == "true" ]]; then
      die "--show-content と --buckets-only は同時に指定できません（中身を取得しないため）。"
    fi
    [[ -z "${CONTENT_DIR}" ]] && CONTENT_DIR="./s3_content_$(date +%Y%m%d_%H%M%S)"
  elif [[ -n "${CONTENT_DIR}" ]]; then
    die "--content-dir は --show-content と併せて指定してください。"
  fi
}

# ---------------------------------------------------------------------------
# 4b. S3 操作権限の判定（ensure_permission_or_switch から呼ばれる）
#     バケット一覧の取得（s3:ListAllMyBuckets）ができるかを軽量に確認する。
#     0=権限あり, 非0=権限なし
# ---------------------------------------------------------------------------
probe_s3_permission() {
  aws s3api list-buckets --query 'Buckets[0].Name' --output text >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 5. 前提確認
# ---------------------------------------------------------------------------
preflight() {
  require_command aws

  # 認証チェック（未認証なら aws login --remote を促して終了）
  require_aws_authenticated

  # S3 操作権限の確認（無ければスイッチバック: 自動 or 警告終了）
  #   ※ CodeCommit の操作は行わないため、確認は S3 のみ。
  ensure_permission_or_switch \
    "S3" probe_s3_permission \
    "${AUTO_SWITCH_BACK}" "${SWITCH_BACK_SCRIPT}" "スイッチバック"
}

# ---------------------------------------------------------------------------
# 6. CSV 出力ヘルパー
#    Excel でそのまま開けるよう UTF-8 BOM + CRLF で出力する。
# ---------------------------------------------------------------------------

# CSV 1 フィールドをエスケープして標準出力へ（" を "" に、全体を " で囲む）
csv_field() {
  local v="${1-}"
  v="${v//\"/\"\"}"
  printf '"%s"' "${v}"
}

# CSV 1 行を OUTPUT_CSV へ追記する（引数 = 各フィールド）
csv_row() {
  [[ "${NO_CSV}" == "true" ]] && return 0
  local line="" f
  for f in "$@"; do
    [[ -n "${line}" ]] && line+=","
    line+="$(csv_field "${f}")"
  done
  printf '%s\r\n' "${line}" >> "${OUTPUT_CSV}"
}

# CSV ファイルを初期化（BOM + ヘッダ行）
csv_init() {
  [[ "${NO_CSV}" == "true" ]] && return 0
  local dir
  dir="$(dirname "${OUTPUT_CSV}")"
  [[ -d "${dir}" ]] || die "CSV 出力先のディレクトリが存在しません: ${dir}"

  # UTF-8 BOM（Excel が文字コードを正しく判定するために必要）
  printf '\xEF\xBB\xBF' > "${OUTPUT_CSV}" \
    || die "CSV ファイルを作成できません: ${OUTPUT_CSV}"
  csv_row "バケット名" "種別" "階層" "パス" "名前" "サイズ(バイト)" "最終更新日時(UTC)" "ストレージクラス"
}

# ---------------------------------------------------------------------------
# 7. 表示ヘルパー
# ---------------------------------------------------------------------------

# バイト数を人が読みやすい単位に変換して echo する（例: 1536 -> 1.5 KiB）
human_size() {
  local bytes="${1:-0}"
  awk -v b="${bytes}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i];
    else        printf "%.1f %s", b, u[i];
  }'
}

# 桁区切りカンマ付きの数値を echo する（例: 1234567 -> 1,234,567）
with_commas() {
  printf '%s' "${1}" | awk '{ printf "%\047d", $0 }' 2>/dev/null || printf '%s' "${1}"
}

# 内容出力ファイル数（--show-content 使用時に main のサマリで表示）
CONTENT_FILES=0

# ---------------------------------------------------------------------------
# 7b. ファイル内容の表示 / 出力（--show-content）
#     parquet / gz 形式のオブジェクトをダウンロードして内容を画面表示し、
#     同じ内容を CONTENT_DIR 配下のファイルへ出力する。
#     ※ ダウンロード（s3:GetObject）を伴うため、既定では無効（--show-content で有効化）。
# ---------------------------------------------------------------------------

# parquet ファイルを人が読みやすい表形式へ整形して標準出力へ出す。
#   引数: <parquetファイル> <表示行数(0=全件)>
#   pyarrow / pandas / parquet-tools / duckdb のいずれかを利用する。
#   0=成功, 非0=利用可能なツールが無い / 読み取り失敗
render_parquet() {
  local src="${1}"
  local max_rows="${2}"

  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import importlib.util,sys; sys.exit(0 if (importlib.util.find_spec("pyarrow") or importlib.util.find_spec("pandas")) else 1)' >/dev/null 2>&1; then
    python3 - "${src}" "${max_rows}" <<'PY' && return 0
import sys

src = sys.argv[1]
n = int(sys.argv[2])

cols = []
types = []
nrows = 0
rows = []


def load():
    global cols, types, nrows, rows
    try:
        import pyarrow.parquet as pq
        tbl = pq.read_table(src)
        nrows = tbl.num_rows
        schema = tbl.schema
        cols = list(schema.names)
        types = [str(schema.field(i).type) for i in range(len(cols))]
        limit = nrows if n == 0 else min(n, nrows)
        for rec in tbl.slice(0, limit).to_pylist():
            rows.append([rec.get(c) for c in cols])
        return
    except ImportError:
        pass
    import pandas as pd
    df = pd.read_parquet(src)
    nrows = len(df)
    cols = [str(c) for c in df.columns]
    types = [str(t) for t in df.dtypes]
    limit = nrows if n == 0 else min(n, nrows)
    for _, r in df.head(limit).iterrows():
        rows.append([r[c] for c in df.columns])


def cell(v, width=40):
    s = "" if v is None else str(v)
    s = s.replace("\t", " ").replace("\n", " ").replace("\r", " ")
    if len(s) > width:
        s = s[: width - 1] + "…"
    return s


load()

print("[parquet] スキーマ ({} 列):".format(len(cols)))
for c, t in zip(cols, types):
    print("    - {} ({})".format(c, t))
print("[parquet] 総行数: {:,}".format(nrows))

shown = len(rows)
head_cells = [cell(c) for c in cols]
body = [[cell(v) for v in r] for r in rows]
widths = [len(h) for h in head_cells]
for r in body:
    for i, v in enumerate(r):
        if len(v) > widths[i]:
            widths[i] = len(v)

def fmt(vals):
    return " | ".join(v.ljust(widths[i]) for i, v in enumerate(vals))

label = "全 {} 行".format(nrows) if (n == 0 or nrows <= shown) else "先頭 {} 行".format(shown)
print("[parquet] データ ({}):".format(label))
if cols:
    print("    " + fmt(head_cells))
    print("    " + "-+-".join("-" * w for w in widths))
    for r in body:
        print("    " + fmt(r))
PY
  fi

  # フォールバック: parquet-tools / duckdb
  if command -v parquet-tools >/dev/null 2>&1; then
    printf '[parquet] スキーマ:\n'
    parquet-tools schema "${src}" 2>/dev/null | sed 's/^/    /'
    printf '[parquet] データ:\n'
    if [[ "${max_rows}" -gt 0 ]]; then
      parquet-tools head -n "${max_rows}" "${src}" 2>/dev/null | sed 's/^/    /'
    else
      parquet-tools cat "${src}" 2>/dev/null | sed 's/^/    /'
    fi
    return 0
  fi
  if command -v duckdb >/dev/null 2>&1; then
    local lim=""
    [[ "${max_rows}" -gt 0 ]] && lim=" LIMIT ${max_rows}"
    printf '[parquet] データ:\n'
    duckdb -box -c "SELECT * FROM read_parquet('${src}')${lim};" 2>/dev/null | sed 's/^/    /'
    return 0
  fi

  return 1
}

# 内容表示済みメッセージを画面へインデント付きで出す小ヘルパ
content_note() {
  local indent="${1}"; shift
  printf '%s      %s↳ %s%s\n' "${indent}" "${C_YELLOW}" "$*" "${C_RESET}"
}

# 1 オブジェクトの内容を取得して画面表示 + ファイル出力する。
#   引数: <bucket> <region> <key> <size> <画面インデント>
extract_content() {
  local bucket="${1}"
  local region="${2}"
  local key="${3}"
  local size="${4}"
  local indent="${5}"

  # --- 対象拡張子の判定（parquet / gz のみ）---
  local lower="${key,,}"
  local kind=""
  case "${lower}" in
    *.parquet) kind="parquet" ;;
    *.gz)      kind="gz" ;;
    *)         return 0 ;;
  esac

  # --- サイズ上限チェック ---
  if [[ "${size}" =~ ^[0-9]+$ && "${CONTENT_MAX_BYTES}" -gt 0 && "${size}" -gt "${CONTENT_MAX_BYTES}" ]]; then
    content_note "${indent}" "内容表示をスキップ: サイズ $(human_size "${size}") が上限 $(human_size "${CONTENT_MAX_BYTES}") を超過（--content-max-bytes で変更可）"
    return 0
  fi

  mkdir -p "${CONTENT_DIR}" 2>/dev/null || { content_note "${indent}" "内容出力先を作成できません: ${CONTENT_DIR}"; return 0; }

  # --- オブジェクトをダウンロード ---
  local tmpobj
  tmpobj="$(mktemp "${TMPDIR:-/tmp}/s3content.XXXXXX")"
  local get_args=(s3api get-object --bucket "${bucket}" --key "${key}")
  [[ -n "${region}" ]] && get_args+=(--region "${region}")
  get_args+=("${tmpobj}")
  if ! aws "${get_args[@]}" >/dev/null 2>&1; then
    content_note "${indent}" "内容の取得に失敗しました（s3:GetObject 権限を確認してください）"
    rm -f "${tmpobj}"
    return 0
  fi

  # --- 出力先パス（bucket/key の階層を保持）---
  local destbase="${CONTENT_DIR}/${bucket}/${key}"
  local rows="${CONTENT_MAX_ROWS}"
  local lines="${CONTENT_MAX_LINES}"

  if [[ "${kind}" == "parquet" ]]; then
    # --- parquet: 表形式へ整形して表示 + .txt へ出力 ---
    local dest="${destbase}.txt"
    mkdir -p "$(dirname "${dest}")" 2>/dev/null || true
    local rendered
    if rendered="$(render_parquet "${tmpobj}" "${rows}" 2>/dev/null)"; then
      printf '%s' "${rendered}" > "${dest}"
      printf '%s      %s[内容: parquet]%s\n' "${indent}" "${C_GREEN}" "${C_RESET}"
      printf '%s\n' "${rendered}" | sed "s/^/${indent}        /"
      content_note "${indent}" "内容を出力しました: ${dest}"
      CONTENT_FILES=$((CONTENT_FILES + 1))
    else
      content_note "${indent}" "parquet を整形表示できませんでした（pyarrow / pandas / parquet-tools / duckdb のいずれかが必要です）"
    fi

  else
    # --- gz: 自動解凍。中身が parquet ならさらに整形、そうでなければテキスト出力 ---
    local inner="${key%.[gG][zZ]}"     # 末尾 .gz を除去
    local inner_lower="${inner,,}"
    local tmpdec
    tmpdec="$(mktemp "${TMPDIR:-/tmp}/s3decomp.XXXXXX")"
    if ! gunzip -c "${tmpobj}" > "${tmpdec}" 2>/dev/null; then
      content_note "${indent}" "gz の解凍に失敗しました（gzip 形式ではない可能性があります）"
      rm -f "${tmpobj}" "${tmpdec}"
      return 0
    fi

    if [[ "${inner_lower}" == *.parquet ]]; then
      # gz の中身が parquet
      local dest="${CONTENT_DIR}/${bucket}/${inner}.txt"
      mkdir -p "$(dirname "${dest}")" 2>/dev/null || true
      local rendered
      if rendered="$(render_parquet "${tmpdec}" "${rows}" 2>/dev/null)"; then
        printf '%s' "${rendered}" > "${dest}"
        printf '%s      %s[内容: gz -> parquet 解凍済み]%s\n' "${indent}" "${C_GREEN}" "${C_RESET}"
        printf '%s\n' "${rendered}" | sed "s/^/${indent}        /"
        content_note "${indent}" "内容を出力しました: ${dest}"
        CONTENT_FILES=$((CONTENT_FILES + 1))
      else
        content_note "${indent}" "解凍後の parquet を整形表示できませんでした（pyarrow / pandas / parquet-tools / duckdb のいずれかが必要です）"
      fi
    else
      # テキスト（想定）として出力
      local dest="${CONTENT_DIR}/${bucket}/${inner}"
      mkdir -p "$(dirname "${dest}")" 2>/dev/null || true
      cp -f "${tmpdec}" "${dest}"
      local total
      total="$(wc -l < "${tmpdec}" | tr -d ' ')"
      printf '%s      %s[内容: gz 解凍済み]%s（%s 行）\n' "${indent}" "${C_GREEN}" "${C_RESET}" "$(with_commas "${total}")"
      if [[ "${lines}" -gt 0 ]]; then
        head -n "${lines}" "${tmpdec}" | sed "s/^/${indent}        /"
        [[ "${total}" -gt "${lines}" ]] && content_note "${indent}" "先頭 ${lines} 行のみ表示（全 $(with_commas "${total}") 行。--content-max-lines 0 で全件）"
      else
        sed "s/^/${indent}        /" "${tmpdec}"
      fi
      content_note "${indent}" "内容を出力しました: ${dest}"
      CONTENT_FILES=$((CONTENT_FILES + 1))
    fi
    rm -f "${tmpdec}"
  fi

  rm -f "${tmpobj}"
}

# ---------------------------------------------------------------------------
# 8. バケットの中身を一覧表示 + CSV 出力
#    list-objects-v2 の結果からディレクトリ(prefix)を導出し、階層インデント
#    付きのリストとして表示する。
#
# usage: list_bucket_contents <bucket> <region>
# ---------------------------------------------------------------------------
list_bucket_contents() {
  local bucket="${1}"
  local region="${2}"

  # --- オブジェクト一覧を取得（タブ区切り: Key Size LastModified StorageClass）---
  #   S3 API はキー名順でしか返さず「最新 N 件」の判定には全件が必要なため、
  #   取得は常に全件行い、表示件数を後段で MAX_KEYS に絞り込む。
  local aws_args=(s3api list-objects-v2 --bucket "${bucket}"
                  --query 'Contents[].[Key,Size,LastModified,StorageClass]'
                  --output text)
  [[ -n "${region}" ]] && aws_args+=(--region "${region}")
  [[ -n "${PREFIX}" ]] && aws_args+=(--prefix "${PREFIX}")

  local raw
  if ! raw="$(aws "${aws_args[@]}" 2>/dev/null)"; then
    log_warn "  バケット '${bucket}' の中身を取得できません（アクセス権限なし、または削除済み）。"
    csv_row "${bucket}" "アクセス不可" "" "" "" "" "" ""
    DENIED_BUCKETS=$((DENIED_BUCKETS + 1))
    return 0
  fi

  # 空バケット（--output text は Contents が無いと "None" を返す）
  if [[ -z "${raw}" || "${raw}" == "None" ]]; then
    if [[ -n "${PREFIX}" ]]; then
      printf '    %s(指定ディレクトリ配下にオブジェクトはありません: %s)%s\n' "${C_YELLOW}" "${PREFIX}" "${C_RESET}"
    else
      printf '    %s(空のバケットです)%s\n' "${C_YELLOW}" "${C_RESET}"
    fi
    csv_row "${bucket}" "空バケット" "" "" "" "" "" ""
    return 0
  fi

  # --- MAX_KEYS > 0 なら最終更新日時(LastModified)の新しい順に上位 N 件へ絞り込む ---
  #   フォルダマーカー（'/' 終わりのキー）は件数に含めない。
  #   打ち切りは head ではなく awk で行う（pipefail での SIGPIPE 失敗を避けるため）。
  local total_files=0
  if [[ "${MAX_KEYS}" -gt 0 ]]; then
    raw="$(printf '%s\n' "${raw}" \
           | awk -F'\t' '$1 != "" && $1 != "None" && $1 !~ /\/$/')"
    total_files="$(printf '%s\n' "${raw}" | grep -c . || true)"
    raw="$(printf '%s\n' "${raw}" \
           | LC_ALL=C sort -t$'\t' -k3,3r \
           | awk -v n="${MAX_KEYS}" 'NR <= n')"
    if [[ -z "${raw}" ]]; then
      printf '    %s(ファイルはありません（フォルダマーカーのみ）)%s\n' "${C_YELLOW}" "${C_RESET}"
      csv_row "${bucket}" "空バケット" "" "" "" "" "" ""
      return 0
    fi
  fi

  # --- ディレクトリ(prefix)の導出とエントリ一覧の構築 ---
  #   エントリ形式（タブ区切り）: <パス> <種別 D/F> <サイズ> <更新日時> <ストレージクラス>
  #   ディレクトリはパス末尾に '/' を付けて登録する（sort で子より先に並ぶ）。
  local entries_file
  entries_file="$(mktemp "${TMPDIR:-/tmp}/s3keycheck.XXXXXX")"

  local key size lm sc dir obj_count=0 obj_bytes=0
  declare -A seen_dirs=()

  while IFS=$'\t' read -r key size lm sc; do
    [[ -n "${key}" && "${key}" != "None" ]] || continue

    # 親ディレクトリを全階層ぶん登録（例: a/b/c.txt -> a/, a/b/）
    dir="${key%/*}"
    if [[ "${dir}" != "${key}" ]]; then
      local built=""
      local part
      while IFS= read -r -d '/' part; do
        built+="${part}/"
        if [[ -z "${seen_dirs[${built}]:-}" ]]; then
          seen_dirs["${built}"]=1
          printf '%s\tD\t\t\t\n' "${built}" >> "${entries_file}"
        fi
      done <<< "${dir}/"
    fi

    # key 自体が '/' 終わりならフォルダマーカー（上で登録済みなのでスキップ）
    [[ "${key}" == */ ]] && continue

    printf '%s\tF\t%s\t%s\t%s\n' "${key}" "${size}" "${lm}" "${sc}" >> "${entries_file}"
    obj_count=$((obj_count + 1))
    obj_bytes=$((obj_bytes + size))
  done <<< "${raw}"

  TOTAL_OBJECTS=$((TOTAL_OBJECTS + obj_count))
  TOTAL_BYTES=$((TOTAL_BYTES + obj_bytes))

  local limited=""
  [[ "${MAX_KEYS}" -gt 0 && "${total_files}" -gt "${MAX_KEYS}" ]] \
    && limited="（全 $(with_commas "${total_files}") 件中、最新 ${MAX_KEYS} 件のみ表示。--max-keys 0 で全件）"
  printf '    オブジェクト数: %s / 合計サイズ: %s%s\n' \
    "$(with_commas "${obj_count}")" "$(human_size "${obj_bytes}")" "${limited}"

  # --- 階層インデント付きで表示 + CSV 出力 ---
  local path type name depth indent slashes
  while IFS=$'\t' read -r path type size lm sc; do
    if [[ "${type}" == "D" ]]; then
      # ディレクトリ: 末尾 '/' を除いた深さ = インデント段数
      slashes="${path//[!\/]/}"
      depth=$(( ${#slashes} - 1 ))
      name="${path%/}"; name="${name##*/}/"
      indent="$(printf '%*s' $((depth * 2)) '')"
      printf '    %s%s[DIR ] %s%s\n' "${indent}" "${C_BLUE}" "${name}" "${C_RESET}"
      csv_row "${bucket}" "ディレクトリ" "${depth}" "${path}" "${name}" "" "" ""
    else
      slashes="${path//[!\/]/}"
      depth=${#slashes}
      name="${path##*/}"
      indent="$(printf '%*s' $((depth * 2)) '')"
      printf '    %s[FILE] %s  (%s, %s)\n' \
        "${indent}" "${name}" "$(human_size "${size}")" "${lm}"
      csv_row "${bucket}" "ファイル" "${depth}" "${path}" "${name}" "${size}" "${lm}" "${sc}"
      # parquet / gz なら内容を画面表示 + ファイル出力（--show-content 指定時のみ）
      if [[ "${SHOW_CONTENT}" == "true" ]]; then
        extract_content "${bucket}" "${region}" "${path}" "${size}" "${indent}"
      fi
    fi
  done < <(LC_ALL=C sort -t$'\t' -k1,1 "${entries_file}")

  rm -f "${entries_file}"
}

# ---------------------------------------------------------------------------
# 9. バケットのリージョンを取得（取得できなければ空 = 既定リージョンで続行）
# ---------------------------------------------------------------------------
get_bucket_region() {
  local bucket="${1}"
  local loc
  if ! loc="$(aws s3api get-bucket-location --bucket "${bucket}" \
                --query 'LocationConstraint' --output text 2>/dev/null)"; then
    printf ''
    return 0
  fi
  case "${loc}" in
    None|null) printf 'us-east-1' ;;   # us-east-1 は LocationConstraint が null
    EU)        printf 'eu-west-1' ;;   # 旧形式
    *)         printf '%s' "${loc}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 10. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight

  log_info "=== 実行内容 ==="
  log_info "  対象バケット      : ${BUCKET_FILTER:-(確認可能な全バケット)}"
  log_info "  対象ディレクトリ  : ${PREFIX:-(バケット全体)}"
  log_info "  中身の取得        : $([[ "${BUCKETS_ONLY}" == "true" ]] && echo 'しない (--buckets-only)' || echo 'する')"
  if [[ "${SHOW_CONTENT}" == "true" ]]; then
    log_info "  内容表示(parquet/gz): する（出力先: ${CONTENT_DIR}）"
  else
    log_info "  内容表示(parquet/gz): しない（--show-content で有効化）"
  fi
  log_info "  表示オブジェクト数: $([[ "${MAX_KEYS}" -gt 0 ]] && echo "最新 ${MAX_KEYS} 件（--max-keys 0 で無制限）" || echo '無制限')"
  log_info "  CSV 出力          : $([[ "${NO_CSV}" == "true" ]] && echo 'しない' || echo "${OUTPUT_CSV}")"
  log_info "  自動スイッチバック: ${AUTO_SWITCH_BACK}"
  [[ "${AUTO_SWITCH_BACK}" == "true" ]] && \
    log_info "  切替用シェル(back): ${SWITCH_BACK_SCRIPT:-(未指定)}"

  # --- バケット一覧の取得 ---
  local buckets_raw
  if ! buckets_raw="$(aws s3api list-buckets \
                        --query 'Buckets[].[Name,CreationDate]' --output text)"; then
    die "バケット一覧の取得に失敗しました（s3:ListAllMyBuckets 権限を確認してください）。"
  fi
  if [[ -z "${buckets_raw}" || "${buckets_raw}" == "None" ]]; then
    log_warn "現在の権限で確認可能なバケットはありません。"
    exit 0
  fi

  # --bucket 指定によるフィルタ用の連想配列
  declare -A filter=()
  if [[ -n "${BUCKET_FILTER}" ]]; then
    local b
    IFS=',' read -ra _wanted <<< "${BUCKET_FILTER}"
    for b in "${_wanted[@]}"; do filter["${b}"]=1; done
  fi

  csv_init

  log_info "=== S3 バケット一覧 ==="
  local name created region matched=0
  while IFS=$'\t' read -r name created; do
    [[ -n "${name}" ]] || continue
    if [[ -n "${BUCKET_FILTER}" && -z "${filter[${name}]:-}" ]]; then
      continue
    fi
    matched=$((matched + 1))
    TOTAL_BUCKETS=$((TOTAL_BUCKETS + 1))

    printf '\n%s[バケット]%s %s  (作成日時: %s)\n' "${C_GREEN}" "${C_RESET}" "${name}" "${created}"
    csv_row "${name}" "バケット" "" "" "${name}" "" "${created}" ""

    if [[ "${BUCKETS_ONLY}" != "true" ]]; then
      region="$(get_bucket_region "${name}")"
      [[ -n "${region}" ]] && log_debug "バケット '${name}' のリージョン: ${region}"
      list_bucket_contents "${name}" "${region}"
    fi
  done <<< "${buckets_raw}"

  if [[ -n "${BUCKET_FILTER}" && "${matched}" -eq 0 ]]; then
    die "--bucket で指定されたバケットは、現在の権限で確認可能な一覧に存在しません: ${BUCKET_FILTER}"
  fi

  # --- サマリ ---
  printf '\n'
  log_info "=== サマリ ==="
  log_info "  バケット数        : $(with_commas "${TOTAL_BUCKETS}")"
  if [[ "${BUCKETS_ONLY}" != "true" ]]; then
    log_info "  オブジェクト総数  : $(with_commas "${TOTAL_OBJECTS}")"
    log_info "  合計サイズ        : $(human_size "${TOTAL_BYTES}")"
    [[ "${DENIED_BUCKETS}" -gt 0 ]] && \
      log_warn "  アクセス不可      : ${DENIED_BUCKETS} バケット（一覧のみ確認可能）"
    [[ "${SHOW_CONTENT}" == "true" ]] && \
      log_info "  内容出力ファイル  : $(with_commas "${CONTENT_FILES}") 件（出力先: ${CONTENT_DIR}）"
  fi

  if [[ "${NO_CSV}" != "true" ]]; then
    log_success "CSV を出力しました（Excel でそのまま開けます）: ${OUTPUT_CSV}"
  fi
  if [[ "${SHOW_CONTENT}" == "true" && "${CONTENT_FILES}" -gt 0 ]]; then
    log_success "parquet / gz の内容を出力しました: ${CONTENT_DIR}"
  fi
  log_success "完了しました。"
}

main "$@"
