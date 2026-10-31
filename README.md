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
