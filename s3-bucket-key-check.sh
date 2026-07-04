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
MAX_KEYS="50"               # 各バケットで表示する最新オブジェクト数（0 = 無制限）
BUCKETS_ONLY="false"        # true ならバケット一覧のみ（中身は取得しない）
OUTPUT_CSV=""               # CSV 出力先パス。空なら既定名で出力
NO_CSV="false"              # true なら CSV 出力を行わない

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
  --max-keys <n>             各バケットで表示するオブジェクト数の上限
                             （最終更新日時の新しい順に n 件。既定: 50。
                              0 を指定すると無制限に全件表示する）
  --buckets-only             バケット一覧のみ表示し、中身の取得を行わない
  --output <path>            CSV 出力先ファイルパス
                             （既定: ./s3_bucket_list_<日時>.csv）
  --no-csv                   CSV ファイル出力を行わない（画面表示のみ）
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
      --max-keys)           MAX_KEYS="${2:-}"; shift 2 ;;
      --buckets-only)       BUCKETS_ONLY="true"; shift 1 ;;
      --output)             OUTPUT_CSV="${2:-}"; shift 2 ;;
      --no-csv)             NO_CSV="true"; shift 1 ;;
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

  local raw
  if ! raw="$(aws "${aws_args[@]}" 2>/dev/null)"; then
    log_warn "  バケット '${bucket}' の中身を取得できません（アクセス権限なし、または削除済み）。"
    csv_row "${bucket}" "アクセス不可" "" "" "" "" "" ""
    DENIED_BUCKETS=$((DENIED_BUCKETS + 1))
    return 0
  fi

  # 空バケット（--output text は Contents が無いと "None" を返す）
  if [[ -z "${raw}" || "${raw}" == "None" ]]; then
    printf '    %s(空のバケットです)%s\n' "${C_YELLOW}" "${C_RESET}"
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
  log_info "  中身の取得        : $([[ "${BUCKETS_ONLY}" == "true" ]] && echo 'しない (--buckets-only)' || echo 'する')"
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
  fi

  if [[ "${NO_CSV}" != "true" ]]; then
    log_success "CSV を出力しました（Excel でそのまま開けます）: ${OUTPUT_CSV}"
  fi
  log_success "完了しました。"
}

main "$@"
