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

# 特定バケットのみ（カンマ区切りで複数可）、先頭 500 オブジェクトまで
./s3-bucket-key-check.sh --bucket my-bucket-a,my-bucket-b --max-keys 500

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
| `--max-keys <n>` | 各バケットで取得する最大オブジェクト数（既定: 0 = 無制限） |
| `--buckets-only` | バケット一覧のみ表示 |
| `--output <path>` | CSV 出力先（既定: `./s3_bucket_list_<日時>.csv`） |
| `--no-csv` | CSV 出力を行わない |
| `--auto-switch-back` | S3 権限が無い場合に自動でスイッチバック |
| `--switch-back-script <path>` | スイッチバック専用シェルのパス（`SWITCH_BACK_SCRIPT` 環境変数でも可） |
| `--debug` | デバッグログを出力 |
| `-h, --help` | ヘルプを表示 |
