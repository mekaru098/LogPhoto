# LogPhoto

iPhone 16 Pro 向けのカメラアプリ（Apple Log の静止画 / RAW+Log）。SwiftUI + AVFoundation。
プロジェクトは XcodeGen で生成する（`project.yml` が元。`LogPhoto.xcodeproj` は git に入れない）。

## 実機での確認（Mac + USB 接続の iPhone）

```
scripts/run_on_device.sh              # ビルド → インストール → 起動 → ログ回収
scripts/run_on_device.sh --wait 20    # 起動後 20 秒待ってログ回収（人が iPhone を操作する時間）
scripts/run_on_device.sh --no-build   # ビルドを省く
scripts/run_on_device.sh --log-only   # ログだけ回収
```

- 設定は `scripts/device.env`（`device.env.example` を参照）。git には入れない。
- ログは `logs/device-<日時>.log` に保存される。アプリ内のログは `DebugLog.swift`（`dlog("カテゴリ", "メッセージ")`）。
- iPhone はロック解除・USB 接続・デベロッパモードオン・開発元を信頼済みであること。
- 無料 Apple ID の署名は 7 日で切れる。切れたらスクリプトで入れ直す。

## 不具合調査の流れ

1. 実機で再現する（または自動テストモードを走らせる）
2. `scripts/run_on_device.sh --log-only` でログを取り、`[session]` `[lens]` `[raw]` `[save]` `[memory]` を読む
3. 原因を直し、`scripts/run_on_device.sh` で再確認する

## 注意

- 変更を push すると GitHub Actions がビルドして IPA を Release に置く（サイドロード用）。
- `main` に直接 push する運用。Mac と別環境の Claude が同じリポジトリを触るので、作業前に `git pull` する。
- 実機でのビルドはこのスクリプトで確認する。この環境（Linux）では Swift をコンパイルできない。
