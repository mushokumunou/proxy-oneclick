# proxy.sh

**HTTP / HTTPS / SOCKS5 / SSH** プロキシを、新規 Linux サーバーに一発で導入するインストーラーです。
ユーザー名・パスワード・ポートはすべてランダム生成し、ufw など のファイアウォール開放まで自動で行い、
接続情報を `/root/proxy.json` に書き出します。対話操作は一切ありません。

## クイックスタート

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)
```

## 導入されるもの

| プロトコル | 実装 | 備考 |
|-----------|------|------|
| HTTP   | sing-box `http` inbound        | 平文 HTTP と HTTPS 先（`CONNECT`）の両方に対応 |
| HTTPS  | sing-box `http` inbound + TLS  | プロキシ自体が TLS で待ち受け（自己署名証明書） |
| SOCKS5 | sing-box `socks` inbound       | リモート DNS（`socks5h`）対応 |
| SSH    | システムの `sshd` + 専用ユーザー | **そのユーザーのみ** `-D`（動的 SOCKS）/ `-L`（ポート転送）を許可 |

プロキシ各プロトコルは 1 組のランダムなユーザー名／パスワードを共有します。
ポートは 20000-59999 の範囲から、実際に空いているものを選びます。

## 対応 OS

* Alpine Linux（OpenRC）— 3.24 で検証済み
* Debian / Ubuntu（systemd）

アーキテクチャ: `x86_64` / `aarch64` / `armv7`。

> Alpine では `apk add sing-box` のパッケージ版を使用します。上流のリリースバイナリは
> glibc に動的リンクされており musl（Alpine）では実行できないため、Alpine では使いません。
> Debian/Ubuntu では公式リリースのバイナリをダウンロードします。

## 必要要件

* root 権限（プロキシ関連の設定のみ変更し、既存の root の SSH アクセスは削除しません）
* 外向きインターネット接続（パッケージ導入、Debian では sing-box のダウンロード）

## インストール

サーバー上で root として 1 コマンド実行します。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)
```

オプションはプロセス置換の後ろに付けます。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh) --test
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh) --force
```

bash が無い / プロセス置換が使えない場合（最小構成の Alpine）:

```bash
sh -c "$(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)"
```

> この 1 行コマンドは、**bash** がその行を解釈する必要があります。ログインシェルが
> `/bin/sh`（Alpine の root 既定）の場合は、先に `bash` を起動するか、次の形で実行してください。
>
> ```bash
> bash -c 'bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)'
> ```

ファイルをサーバーに置いて実行したい場合:

```bash
scp proxy.sh root@YOUR_SERVER:/root/proxy.sh
ssh root@YOUR_SERVER 'sh /root/proxy.sh'
```

なお 1 コマンド版はスクリプト自身を保存しません。再実行用にローカルへ置く場合:

```bash
curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh -o /root/proxy.sh
sh /root/proxy.sh
```

完了時に JSON が表示され、同じ内容が次に保存されます（パーミッション 600）。

```
/root/proxy.json
/roo/proxy.json
/etc/sing-box/proxy.env   # 再実行時に認証情報を引き継ぐための状態ファイル
```

## 使い方

```bash
sh /root/proxy.sh              # 導入 / 再適用（既存の認証情報とポートを再利用）
sh /root/proxy.sh --force      # 認証情報とポートを作り直して再構築
sh /root/proxy.sh --test       # 導入後に 127.0.0.1 経由で自己テスト
sh /root/proxy.sh --help
```

`--force` なしの再実行は安全です（認証情報・ポート・設定を再利用するため、既存クライアントは切れません）。

## 接続例

```bash
# HTTP プロキシ（HTTPS 先・HTTP 先どちらも可）
curl -x http://USER:PASS@SERVER:PORT_HTTP https://api.ipify.org

# HTTPS プロキシ（自己署名証明書なので検証をスキップ）
curl --proxy-insecure -x https://USER:PASS@SERVER:PORT_HTTPS https://api.ipify.org

# SOCKS5（リモート DNS）
curl --socks5-hostname USER:PASS@SERVER:PORT_SOCKS https://api.ipify.org

# SSH: 動的 SOCKS トンネル（ローカル 1080 番）
ssh -N -D 127.0.0.1:1080 SSH_USER@SERVER -p 22
# そのあと、クライアントを socks5h://127.0.0.1:1080 に向ける

# SSH: ローカルポート転送（サーバー側から見たホストへ到達）
ssh -N -L 127.0.0.1:8080:target.host:80 SSH_USER@SERVER -p 22
```

## 動作確認

`/root/proxy.json` の値を入れて実行します。

```bash
H=SERVER
U=USERNAME
P=PASSWORD
curl -s -x "http://$U:$P@$H:PORT_HTTP"  https://api.ipify.org   # サーバーの IP が返る
curl -s --proxy-insecure -x "https://$U:$P@$H:PORT_HTTPS" https://api.ipify.org
curl -s --socks5-hostname "$U:$P@$H:PORT_SOCKS" https://api.ipify.org
ssh SSH_USER@$H -p 22 'echo ok'
```

いずれも **手元の IP ではなくサーバーの IP** が返る（SSH はログイン成功）ことを確認してください。
誤ったパスワードは拒否される必要があります。

## サービス管理

```bash
# Alpine (OpenRC)
rc-service sing-box status|restart
rc-service sshd reload

# Debian/Ubuntu (systemd)
systemctl status|restart sing-box
systemctl reload ssh
```

設定: `/etc/sing-box/config.json`、TLS 証明書: `/etc/sing-box/tls/`。

## 注意点

* HTTPS プロキシは自己署名証明書です。curl なら `--proxy-insecure`、ブラウザなら例外承認
  （または証明書を信頼登録）が必要です。暗号化自体は有効で、第三者による検証だけがありません。
* `sshd` の変更は明示的なマーカーのブロック内で行い、生成したプロキシユーザーにだけ
  `AllowTcpForwarding yes` を与えます。変更前のファイルは
  `/etc/ssh/sshd_config.pre-proxy.sh` に保存し、リロード前に `sshd -t` で検証、
  失敗時は自動でバックアップへ戻します。
* ファイアウォールは `ufw`（無ければ `firewalld`、Debian で管理ツールが無効なら iptables）で開放します。
  クラウド側のファイアウォールグループがある場合は、そちらでも 3 つのポートを開放してください。
* sing-box のログは `warn` レベルのみで、通信内容の記録は行いません。

## アンインストール

```bash
rc-service sing-box stop; rc-update del sing-box default; rm -f /etc/init.d/sing-box
rm -rf /etc/sing-box /usr/local/bin/sing-box

userdel -r SSH_USER
sed -i '/# >>> proxy.sh managed block >>>/,/# <<< proxy.sh managed block <<</d' /etc/ssh/sshd_config
sshd -t && rc-service sshd reload
```

## ライセンス

MIT
