# LogPhoto — iPhone 16 Pro 向け Log写真 試作

動画の Apple Log を静止画でも使うためのカメラアプリ試作（方式A）。
Apple Log のビデオフレームを、シャッター時に写真として保存します。

## ビルド（Macなし・無料クラウド）
このリポジトリに push すると GitHub Actions が自動でビルドします。
- Actions タブの「Build (unsigned, compile check)」が緑 = コンパイル成功
- 仕組み: クラウドMac上で XcodeGen が `project.yml` から Xcode プロジェクトを生成し、
  署名なしで `xcodebuild` を実行します

## 注意
- このビルドは署名なし（コンパイル確認専用）です。
  iPhone 16 Pro 実機に入れるには Apple Developer Program（$99/年）での
  署名 + TestFlight が別途必要です。
- Bundle ID は仮で `com.example.logphoto` です。

## 構成
- `*.swift` — アプリ本体（SwiftUI + AVFoundation、Apple Log は第1世代）
- `project.yml` — XcodeGen 用プロジェクト定義
- `.github/workflows/build.yml` — 無料クラウドビルド設定
