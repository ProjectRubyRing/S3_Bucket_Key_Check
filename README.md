# S3_Bucket_Key_Check

現在の IAM 権限で確認可能な S3 バケットの一覧と、各バケットに含まれる
ディレクトリ(prefix)/ファイル(オブジェクト)を階層リスト形式で表示するツールです。
あわせて、Excel でそのまま開ける CSV ファイル（UTF-8 BOM 付き / CRLF）へ出力できます。

## 構成

| ファイル | 役割 |
| --- | --- |
| `s3-bucket-key-check.sh` | 本体スクリプト |
| `common.sh` | 共通ユーティリティ（ログ / 認証チェック / 権限確認+スイッチ処理。Codecommit_Git_Tags_S3_Upload と共通） |

## 前提

- bash / AWS CLI v2
- 実行前に `aws login --remote` で認証しておくこと
  （未認証の場合は警告メッセージを表示して終了します）
- 必要な IAM 権限: `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:ListBucket`
  （読み取り専用。S3 への書き込みは一切行いません。CodeCommit の操作も不要です）

## 使い方

```bash
# 全バケットの中身を一覧表示し、既定名（./s3_bucket_list_<日時>.csv）で CSV 出力
./s3-bucket-key-check.sh

# 特定バケットのみ（カンマ区切りで複数可）、最新 500 オブジェクトまで
./s3-bucket-key-check.sh --bucket my-bucket-a,my-bucket-b --max-keys 500

# バケット内の特定ディレクトリ(prefix)配下だけを対象にする
./s3-bucket-key-check.sh --bucket my-bucket-a --prefix logs/2026/

# parquet / gz ファイルの中身も画面表示しファイルへ出力する
./s3-bucket-key-check.sh --bucket my-data --prefix export/ --show-content

# 件数制限なしで全オブジェクトを表示（既定は最新 50 件まで）
./s3-bucket-key-check.sh --max-keys 0

# バケット一覧のみ（中身は取得しない）
./s3-bucket-key-check.sh --buckets-only

# CSV 出力先を指定 / CSV 出力しない
./s3-bucket-key-check.sh --output /tmp/s3_list.csv
./s3-bucket-key-check.sh --no-csv
```

## S3 権限が無い場合（スイッチバック）

スイッチロール中などで S3 の操作権限が無い場合の挙動をオプションで切り替えられます。

- **既定**: 「スイッチバックしてから再実行してください」と警告して終了します。
- **`--auto-switch-back`**: 別チーム提供のスイッチバック専用シェルを `source` で
  呼び出して自動でスイッチバックし、権限を再確認してから処理を続行します。

```bash
# 警告して終了（案内メッセージに切替用シェルのパスを表示）
./s3-bucket-key-check.sh --switch-back-script /path/to/switch_back.sh

# 自動でスイッチバックして続行
./s3-bucket-key-check.sh --auto-switch-back --switch-back-script /path/to/switch_back.sh

# 切替用シェルのパスは環境変数でも指定可能
export SWITCH_BACK_SCRIPT=/path/to/switch_back.sh
./s3-bucket-key-check.sh --auto-switch-back
```

## バケット内ディレクトリの指定（`--prefix`）

`--prefix <dir>` で、バケット直下ではなく特定のディレクトリ(prefix)配下だけを
対象にできます。`--bucket` と組み合わせると、対象バケット内の任意の階層に
絞り込めます。

```bash
# data/2026/ 配下のオブジェクトだけを一覧表示
./s3-bucket-key-check.sh --bucket my-data --prefix data/2026/
```

- prefix は前方一致で適用されます（例: `logs/` は `logs/` で始まる全キー）。
- 指定した prefix 配下にオブジェクトが無い場合は、その旨を表示します。

## parquet / gz ファイルの内容表示（`--show-content`）

`--show-content` を付けると、一覧に表示された **parquet / gz 形式** の
ファイルをダウンロードして中身を画面へ表示し、同じ内容をファイルへも出力します。

- **parquet**: スキーマ（列名・型）・総行数・先頭データを **表形式** で整形して
  表示します（`pyarrow` / `pandas` / `parquet-tools` / `duckdb` のいずれかを利用）。
- **gz**: 自動で解凍して内容を表示します。中身がテキストならそのまま、
  中身が parquet（`*.parquet.gz`）なら解凍後に parquet として表形式で表示します。
- 内容は `--content-dir`（既定: `./s3_content_<日時>`）配下に、
  `<バケット名>/<キーの階層>` を保持したファイルとして出力します。
  - parquet     : 整形結果を `<キー>.txt` として出力
  - gz（テキスト）: 解凍後の内容を（`.gz` を除いた元の名前で）出力
  - gz（parquet） : 解凍・整形結果を `<キー(.gz除去)>.txt` として出力

```bash
# 対象を絞って（推奨）内容を表示・出力する
./s3-bucket-key-check.sh --bucket my-data --prefix export/ --show-content

# 表示行数や取得サイズ上限を調整する
./s3-bucket-key-check.sh --bucket my-data --prefix export/ --show-content \
    --content-max-rows 100 --content-max-lines 200 --content-max-bytes 104857600
```

> **注意**
> - この機能は S3 オブジェクトの **ダウンロード（`s3:GetObject` 権限）** を伴います。
>   誤って大量・巨大なファイルを取得しないよう、既定では無効（`--show-content` で明示的に有効化）
>   とし、1 オブジェクトあたり `--content-max-bytes`（既定 50MiB）を超えるものは
>   スキップします。`--bucket` / `--prefix` / `--max-keys` で対象を絞ることを推奨します。
> - parquet の整形表示には `pyarrow` / `pandas` / `parquet-tools` / `duckdb` の
>   いずれかが必要です。いずれも無い場合は、その旨を表示して一覧処理は継続します。

## 出力イメージ

画面表示（階層インデント付きリスト）:

```
[バケット] bucket-alpha  (作成日時: 2025-01-15T09:30:00+00:00)
    オブジェクト数: 4 / 合計サイズ: 3.2 MiB
    [FILE] README.md  (1.0 KiB, 2026-06-01T10:00:00+00:00)
    [DIR ] data/
      [DIR ] input/
        [FILE] sales.csv  (3.0 MiB, 2026-06-15T14:30:00+00:00)
    [DIR ] logs/
      [DIR ] 2026/
        [DIR ] 06/
          [FILE] app.log  (200.0 KiB, 2026-06-30T23:59:00+00:00)
```

CSV（Excel でそのまま開けます）の列:

```
バケット名, 種別, 階層, パス, 名前, サイズ(バイト), 最終更新日時(UTC), ストレージクラス
```

種別は `バケット` / `ディレクトリ` / `ファイル` / `空バケット` / `アクセス不可` のいずれかです。
中身を取得できないバケット（アクセス権限なし）は警告を表示して `アクセス不可` として記録し、
処理は継続します。

## 主なオプション

| オプション | 説明 |
| --- | --- |
| `--bucket <name[,name...]>` | 対象バケットを限定（既定: 確認可能な全バケット） |
| `--prefix <dir>` | バケット内のディレクトリ(prefix)を指定し、その配下だけを対象にする（既定: バケット全体） |
| `--max-keys <n>` | 各バケットで表示するオブジェクト数の上限。最終更新日時の新しい順に n 件（既定: 50。`0` = 無制限） |
| `--buckets-only` | バケット一覧のみ表示 |
| `--output <path>` | CSV 出力先（既定: `./s3_bucket_list_<日時>.csv`） |
| `--no-csv` | CSV 出力を行わない |
| `--show-content` | parquet / gz ファイルの内容を画面表示しファイルへ出力（既定: 無効） |
| `--content-dir <path>` | `--show-content` の内容出力先（既定: `./s3_content_<日時>`） |
| `--content-max-bytes <n>` | 内容取得の対象とするオブジェクト最大サイズ(バイト)（既定: `52428800` = 50MiB） |
| `--content-max-rows <n>` | parquet の表示・変換行数の上限（既定: 50。`0` = 無制限） |
| `--content-max-lines <n>` | gz などテキスト内容の表示行数の上限（既定: 100。`0` = 無制限） |
| `--auto-switch-back` | S3 権限が無い場合に自動でスイッチバック |
| `--switch-back-script <path>` | スイッチバック専用シェルのパス（`SWITCH_BACK_SCRIPT` 環境変数でも可） |
| `--debug` | デバッグログを出力 |
| `-h, --help` | ヘルプを表示 |
