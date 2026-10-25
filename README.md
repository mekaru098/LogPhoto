# LogPhoto — iPhone 16 Pro 向け Log写真 試作

動画の Apple Log を静止画でも使うためのカメラアプリ試作です。

## 撮影モード
- **Logフレーム（方式A）**: Apple Log のビデオフレームを、シャッター時に写真として保存します。
- **RAW+Log（方式B）**: Bayer RAW で撮影し、DNG をそのまま保存します。あわせて RAW を現像し、Log カーブ（近似）で変換した JPEG も保存します。

## v1.1 の操作
- 三分割グリッドの表示 ON/OFF
- 露出補正スライダー（-2EV〜+2EV）

> 方式Bの Log 変換は Apple Log の厳密な変換ではなく近似です。実機での色検証は今後の課題です。

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
