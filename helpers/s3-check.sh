#!/usr/bin/env bash
#
# s3-check.sh  —  s3-bucket-key-check.sh 用ラッピングヘルパー
# ==========================================================
# 本体スクリプト（../s3-bucket-key-check.sh）はオプションが多く、毎回すべてを
# 手で入力するのは大変です。このヘルパーは:
#
#   1. よく使う値を「ヘルパー既定値（プリセット）」として上部にまとめて持ち、
#      入力する項目を極力減らす。
#   2. 「外部からどうしても指定が必要な項目（例: --bucket）」だけ引数チェックし、
#      不足していれば usage を表示して終了する。
#   3. 別ディレクトリに置いても本体・common.sh・スイッチバック用シェルを
#      正しく解決できるよう、パスを絶対パス化して本体へ渡す。
#
# スイッチロール（source）制御について:
#   本体はスイッチバック用シェルを「自分のプロセス内で source」し、その同じ
#   プロセスで以降の S3 API を実行するため、ロール切替が正しく反映されます。
#   このヘルパーは本体を *source せず* サブプロセスとして実行（exec）します。
#     - 本体は自前で `source common.sh`（BASH_SOURCE 基準・cwd 非依存）と
#       `source <スイッチバック>` を行うため、ディレクトリを分けても問題なし。
#     - スイッチバック用シェルのパスは絶対パス化して渡すので、cwd に依存せず
#       source が成功します。
#     - ヘルパーが本体を source すると本体の `set -e` / `exit` がヘルパーへ
#       波及して危険なため、あえて exec（サブプロセス実行）にしています。
#
# 使い方:
#   ./s3-check.sh --bucket <name[,name...]> [補助オプション] [-- 本体への追加引数...]
#   ./s3-check.sh --help
#
set -Eeuo pipefail

# ===========================================================================
# 0. ヘルパー既定値（プリセット） — ここを編集すれば入力を減らせます
#    すべて環境変数でも上書き可能（例: MAX_KEYS=200 ./s3-check.sh ...）。
# ===========================================================================

# 本体スクリプトのパス。既定はこのヘルパーの 1 つ上の階層。
# 別レイアウトに置く場合は環境変数 S3_CHECK_MAIN_SCRIPT で上書き可能。
MAIN_SCRIPT="${S3_CHECK_MAIN_SCRIPT:-}"

# 別チーム提供の「スイッチバック用シェル」の既定パス。
#   ここに実パスを書いておけば、毎回 --switch-back-script を打たずに済みます。
#   環境変数 SWITCH_BACK_SCRIPT でも指定可能。
DEFAULT_SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"

# S3 権限が無いとき自動でスイッチバックするか（true 推奨: スイッチロール中でも動く）
DEFAULT_AUTO_SWITCH_BACK="${AUTO_SWITCH_BACK:-true}"

# 各バケットで表示する最新オブジェクト数（0 = 無制限）
DEFAULT_MAX_KEYS="${MAX_KEYS:-100}"

# parquet / gz の内容を表示・出力するか（true / false）
DEFAULT_SHOW_CONTENT="${SHOW_CONTENT:-false}"

# バケット内ディレクトリ(prefix)の既定（空 = バケット全体）
DEFAULT_PREFIX="${PREFIX:-}"

# CSV を出力しない場合は true（既定は本体既定に従い CSV 出力する）
DEFAULT_NO_CSV="${NO_CSV:-false}"

# 常に本体へ渡したい追加オプションがあればここに列挙（自由に追加可）。
#   例: EXTRA_ARGS=(--content-max-lines 200)
EXTRA_ARGS=()

# ===========================================================================
# 1. 自身の位置と本体パスの解決（cwd 非依存）
# ===========================================================================
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_NAME="$(basename "${BASH_SOURCE[0]}")"

# 本体の既定パス = ヘルパーの 1 つ上の階層。未指定時のみ補完。
if [[ -z "${MAIN_SCRIPT}" ]]; then
  MAIN_SCRIPT="${HELPER_DIR}/../s3-bucket-key-check.sh"
fi

# パスを絶対パス化する（存在しなくてもディレクトリ部が実在すれば解決する）。
abspath() {
  local p="$1"
  if [[ -d "${p}" ]]; then
    (cd "${p}" && pwd)
  else
    local d b
    d="$(cd "$(dirname "${p}")" 2>/dev/null && pwd)" || return 1
    b="$(basename "${p}")"
    printf '%s/%s' "${d}" "${b}"
  fi
}

err() { printf '[%s][ERROR] %s\n' "${HELPER_NAME}" "$*" >&2; }

# ===========================================================================
# 2. 使い方
# ===========================================================================
usage() {
  cat >&2 <<USAGE
使い方:
  ${HELPER_NAME} --bucket <name[,name...]> [補助オプション] [-- 本体への追加引数...]

概要:
  s3-bucket-key-check.sh のラッパーです。よく使う値をプリセットとして持ち、
  最低限の指定だけで実行できます。スイッチバック用シェルのパスは絶対パス化
  して本体へ渡すため、別ディレクトリから実行してもロール切替が動作します。

必須（外部から必ず指定）:
  --bucket <name[,name...]>   対象バケット（カンマ区切りで複数可）

補助オプション（プリセットを上書き。未指定なら既定値を使用）:
  --prefix <dir>              バケット内ディレクトリ(prefix)（既定: ${DEFAULT_PREFIX:-バケット全体}）
  --max-keys <n>              表示オブジェクト数の上限（既定: ${DEFAULT_MAX_KEYS}／0=無制限）
  --show-content              parquet / gz の内容を表示・出力する
  --no-show-content           内容表示を無効化（既定: $([[ "${DEFAULT_SHOW_CONTENT}" == "true" ]] && echo 有効 || echo 無効)）
  --content-dir <path>        内容出力先ディレクトリ（--show-content 時のみ）
  --output <path>             CSV 出力先パス
  --no-csv                    CSV 出力を行わない
  --switch-back-script <path> スイッチバック用シェル（既定: ${DEFAULT_SWITCH_BACK_SCRIPT:-未設定}）
  --no-switch-back            自動スイッチバックを無効化する
  --debug                     デバッグログを出力する
  --dry-run                   本体を実行せず、渡すコマンドラインだけ表示する
  --                          これ以降の引数を本体へそのまま渡す（passthrough）
  -h, --help                  このヘルプを表示

環境変数でもプリセットを上書きできます:
  S3_CHECK_MAIN_SCRIPT, SWITCH_BACK_SCRIPT, AUTO_SWITCH_BACK, MAX_KEYS,
  SHOW_CONTENT, PREFIX, NO_CSV

例:
  # 最小構成（bucket だけ指定。スイッチバックはプリセットの設定に従う）
  ${HELPER_NAME} --bucket my-artifacts

  # prefix と内容表示を付けて実行
  ${HELPER_NAME} --bucket my-data --prefix export/ --show-content

  # スイッチバック用シェルをこの実行だけ指定
  ${HELPER_NAME} --bucket my-data --switch-back-script /path/to/switch_back.sh

  # 本体固有のオプションを passthrough で渡す
  ${HELPER_NAME} --bucket my-data -- --content-max-bytes 104857600
USAGE
}

# ===========================================================================
# 3. 引数パース
# ===========================================================================
BUCKET=""
PREFIX_ARG="${DEFAULT_PREFIX}"
MAXKEYS_ARG="${DEFAULT_MAX_KEYS}"
SHOW_CONTENT_ARG="${DEFAULT_SHOW_CONTENT}"
CONTENT_DIR_ARG=""
OUTPUT_ARG=""
NO_CSV_ARG="${DEFAULT_NO_CSV}"
SWITCH_BACK_ARG="${DEFAULT_SWITCH_BACK_SCRIPT}"
AUTO_SWITCH_BACK_ARG="${DEFAULT_AUTO_SWITCH_BACK}"
DEBUG_ARG="false"
DRY_RUN="false"
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --bucket)              BUCKET="${2:-}"; shift 2 ;;
    --prefix)              PREFIX_ARG="${2:-}"; shift 2 ;;
    --max-keys)            MAXKEYS_ARG="${2:-}"; shift 2 ;;
    --show-content)        SHOW_CONTENT_ARG="true"; shift 1 ;;
    --no-show-content)     SHOW_CONTENT_ARG="false"; shift 1 ;;
    --content-dir)         CONTENT_DIR_ARG="${2:-}"; shift 2 ;;
    --output)              OUTPUT_ARG="${2:-}"; shift 2 ;;
    --no-csv)              NO_CSV_ARG="true"; shift 1 ;;
    --switch-back-script)  SWITCH_BACK_ARG="${2:-}"; shift 2 ;;
    --no-switch-back)      AUTO_SWITCH_BACK_ARG="false"; shift 1 ;;
    --debug)               DEBUG_ARG="true"; shift 1 ;;
    --dry-run)             DRY_RUN="true"; shift 1 ;;
    --)                    shift; PASSTHROUGH=("$@"); break ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage; err "不明なオプションです: ${1}"; exit 2 ;;
  esac
done

# ===========================================================================
# 4. 引数チェック（外部から必須の項目）
# ===========================================================================
if [[ -z "${BUCKET}" ]]; then
  usage
  err "--bucket は必須です（対象バケットを指定してください）。"
  exit 2
fi

# 本体スクリプトの存在確認 + 絶対パス化
if [[ ! -f "${MAIN_SCRIPT}" ]]; then
  err "本体スクリプトが見つかりません: ${MAIN_SCRIPT}"
  err "  S3_CHECK_MAIN_SCRIPT で正しいパスを指定してください。"
  exit 1
fi
MAIN_SCRIPT="$(abspath "${MAIN_SCRIPT}")"

# 自動スイッチバックが有効なら、スイッチバック用シェルは必須（存在確認 + 絶対パス化）
if [[ "${AUTO_SWITCH_BACK_ARG}" == "true" ]]; then
  if [[ -z "${SWITCH_BACK_ARG}" ]]; then
    usage
    err "自動スイッチバックが有効ですが、スイッチバック用シェルが未指定です。"
    err "  --switch-back-script <path> を指定するか、--no-switch-back で無効化してください。"
    err "  （プリセット DEFAULT_SWITCH_BACK_SCRIPT / 環境変数 SWITCH_BACK_SCRIPT でも設定可）"
    exit 2
  fi
  if [[ ! -f "${SWITCH_BACK_ARG}" ]]; then
    err "スイッチバック用シェルが見つかりません: ${SWITCH_BACK_ARG}"
    exit 1
  fi
  # ★ cwd に依存せず source できるよう絶対パス化して本体へ渡す
  SWITCH_BACK_ARG="$(abspath "${SWITCH_BACK_ARG}")"
fi

# max-keys の軽い妥当性チェック（本体でも検証されるが早めに弾く）
[[ "${MAXKEYS_ARG}" =~ ^[0-9]+$ ]] || { err "--max-keys には 0 以上の整数を指定してください: ${MAXKEYS_ARG}"; exit 2; }

# ===========================================================================
# 5. 本体へ渡す引数の組み立て
# ===========================================================================
args=(--bucket "${BUCKET}" --max-keys "${MAXKEYS_ARG}")

[[ -n "${PREFIX_ARG}" ]]      && args+=(--prefix "${PREFIX_ARG}")
[[ "${SHOW_CONTENT_ARG}" == "true" ]] && args+=(--show-content)
[[ -n "${CONTENT_DIR_ARG}" ]] && args+=(--content-dir "${CONTENT_DIR_ARG}")

if [[ "${NO_CSV_ARG}" == "true" ]]; then
  args+=(--no-csv)
elif [[ -n "${OUTPUT_ARG}" ]]; then
  args+=(--output "${OUTPUT_ARG}")
fi

if [[ "${AUTO_SWITCH_BACK_ARG}" == "true" ]]; then
  args+=(--auto-switch-back --switch-back-script "${SWITCH_BACK_ARG}")
fi

[[ "${DEBUG_ARG}" == "true" ]] && args+=(--debug)

# プリセットの固定追加オプション + passthrough
[[ ${#EXTRA_ARGS[@]}  -gt 0 ]] && args+=("${EXTRA_ARGS[@]}")
[[ ${#PASSTHROUGH[@]} -gt 0 ]] && args+=("${PASSTHROUGH[@]}")

# ===========================================================================
# 6. 実行（本体はサブプロセスとして実行。source は本体プロセス内で完結）
# ===========================================================================
if [[ "${DRY_RUN}" == "true" ]]; then
  printf '[%s][DRY-RUN] 実行コマンド:\n' "${HELPER_NAME}" >&2
  printf '  %q' "${MAIN_SCRIPT}" >&2
  for a in "${args[@]}"; do printf ' %q' "${a}" >&2; done
  printf '\n' >&2
  exit 0
fi

exec bash "${MAIN_SCRIPT}" "${args[@]}"
