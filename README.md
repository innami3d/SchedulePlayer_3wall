# GeoBox Player

Mac miniから1系統の4K映像を送出する、macOS向けSwiftアプリです。
プロジェクト → 映像／音声プレイリスト → トラックの構成で管理します。

- 開発環境：Xcode 16以降／Swift 6以降
- 対応OS：macOS 14以降
- 仕様：[REQUIREMENTS.md](REQUIREMENTS.md)

## 開発

Xcodeで`Package.swift`を開き、GeoBoxPlayerを実行します。

```sh
swift test
swift run GeoBoxPlayer
```

Codexの制限された環境でビルドする場合は、SwiftPMのマニフェスト用サンドボックスとの二重適用を避け、キャッシュを作業フォルダに置きます。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```

## アプリの作成・操作

```sh
./scripts/build-app.sh
open "dist/GeoBox Player.app"
```

生成先は`dist/GeoBox Player.app`です。ローカル実行用のアドホック署名を行います。

1. プロジェクト設定で映像出力先と送出リフレッシュレート、音声出力先を選びます。
2. 左側の作成ボタンで映像・音声プレイリストを作成します。
3. Finderからファイルをトラック一覧へドロップします。
4. 初期再生プレイリストと時刻を設定し、保存します。再生ボタンで手動確認できます。
5. 画面をロックすると時刻再生のみになり、手動再生・編集を禁止します。

右クリックで削除・複製・コピー・ペースト・Cut、Deleteキーで登録削除、ドラッグで再生順序を変更できます。コピー・Cut・ペーストはCmd+C/X/V、複製はCmd+D、取り消しはCmd+Zです。メディア実体は削除しません。

[実装・検証記録](docs/IMPLEMENTATION.md)に運用ルール、対応確認済み素材と実機検証が必要な項目をまとめています。映像コーデックのテストはmacOSの映像処理サービスを使用するため、制限のない通常のターミナルで`swift test`を実行してください。

プロジェクトは `.player` ファイル（JSON形式）で保存します。素材ファイルは同梱しません。従来の `.geobox.json` も「開く」から読み込めます。
起動時・プロジェクト読込時は、現在時刻の予定に合わせて素材とループ位置を計算し、動画・音声は該当位置から自動再生します。プレイリストの開始予定から次の切替・終了予定までループ再生します。
