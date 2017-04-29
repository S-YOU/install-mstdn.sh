#!/bin/bash

# 以下編集してください
SERVER_IP=1.2.3.4                                # サーバのグロバルIPアドレス (1.2.3.4)

SPARKPOST_APIKEY=ffffffffffffffffffffffffffffffffffffffff #フル権限 - https://app.sparkpost.com/account/credentials
SPARKPOST_SENDKEY=$SPARKPOST_APIKEY             # フルアクセス当てたくない場合に個別に指定、インスタンスの中にコピーされます

CF_EMAIL="username@domain.tld"                  # CloudFlareのログインメールアドレス
CF_AUTH="cffffffffffffffffffffffffffffffffffff" # https://www.cloudflare.com/a/account/my-account - アカウントごと
CF_ZONE="ffffffffffffffffffffffffffffffff"      # https://www.cloudflare.com/a/overview/$MAIN_DOMAIN - ドメーンごと

SUB_DOMAIN=$1                                    # 利用したいドメーン名（サブドメーンsub.main.com）、通常は第ーパラメータを使用するため基本は編集不要
MAIN_DOMAIN=$(echo $SUB_DOMAIN | cut -d"." -f2-) # メインドメーン、基本は編集不要 (main.com)
# ----- ここまで ------


# ---- 各プログラム利用可能かチェック -------
set -e # エラーあれば即終了
uname -a
docker -v
docker-compose -v
jq --version

# ------ MASTODON APP -------

# 新しいSENDING_DOMAINSと追加し、DKIMを発行
SPARKPOST_RESULT=$(curl -s -H "Content-Type: application/json" -H "Authorization: $SPARKPOST_APIKEY" -X POST -d '{"domain":"'$SUB_DOMAIN'","generate_dkim":true,"shared_with_subaccounts":false}"' "https://api.sparkpost.com/api/v1/sending-domains")
# 確認はこちら、https://app.sparkpost.com/account/sending-domains

# DKIMを収納
DKIM_KEY=$(echo $SPARKPOST_RESULT|echo $SPARKPOST_RESULT|jq -r '.results.dkim.selector')
DKIM_VALUE=$(echo $SPARKPOST_RESULT|echo $SPARKPOST_RESULT|jq -r '.results.dkim.public')

# A レコードを追加
CF_RES1=$(curl -s -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_AUTH" -H "Content-Type: application/json" -X POST -d '{"type":"A","proxied":true,"name":"'$SUB_DOMAIN'","content":"'$SERVER_IP'"}' "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records")

# TXT レコードにDKIMを追加
CF_RES2=$(curl -s -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_AUTH" -H "Content-Type: application/json" -X POST -d '{"type":"TXT","name":"'$DKIM_KEY'._domainkey.'$SUB_DOMAIN'","content":"v=DKIM1; k=rsa; h=sha256; p='$DKIM_VALUE'"}' "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records")

# 結果などは無視していますが、確認したい方は
# echo $DKIM_KEY, $DKIM_VALUE, $CF_RES1, $CF_RES2

mkdir -p $SUB_DOMAIN && cd $SUB_DOMAIN

# 環境ファイルを作成
cat <<EOF>.env.production
REDIS_HOST=redis
REDIS_PORT=6379
# REDIS_DB=0
DB_HOST=db
DB_USER=postgres
DB_NAME=postgres
DB_PASS=
DB_PORT=5432

LOCAL_DOMAIN=$SUB_DOMAIN
LOCAL_HTTPS=true

PAPERCLIP_SECRET=`docker run --rm gargron/mastodon rake secret`
SECRET_KEY_BASE=`docker run --rm gargron/mastodon rake secret`
OTP_SECRET=`docker run --rm gargron/mastodon rake secret`
# 毎回--rm使わずに後で消せば早くなると思います、その分コンテナの名前を持つ必要あり

SMTP_SERVER=smtp.sparkpostmail.com
SMTP_PORT=587
SMTP_LOGIN=SMTP_Injection
SMTP_PASSWORD=$SPARKPOST_SENDKEY
SMTP_FROM_ADDRESS=root@$SUB_DOMAIN

STREAMING_API_BASE_URL=//$SUB_DOMAIN/api/v1/streaming
STREAMING_CLUSTER_NUM=1
EOF

# docker-compose.ymlをダウンロードし、コメント部分をアンコメント
curl -s -O https://raw.githubusercontent.com/tootsuite/mastodon/master/docker-compose.yml
sed -i 's/# / /g' docker-compose.yml
cat <<EOF>>docker-compose.yml
  nginx:
    restart: always
    image: nginx:alpine
    extra_hosts:
      - "$SUB_DOMAIN:172.17.0.1"
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - web
    volumes:
      - ./nginx:/etc/nginx
EOF

# データベースのスキーマなどを作成、アセットなどをコンパイル
docker-compose run --rm web rails db:migrate
docker-compose run --rm web rails assets:precompile
# precompile超遅い、２分ほど時間かかる

# SparkPostのDKIM 確認をここでする。DNS普及のため、わざと時間を空けています。
DKIM_VERIFY=$(curl -s -H "Content-Type: application/json" -H "Authorization: $SPARKPOST_APIKEY" -X POST -d '{"dkim_verify":true}"' "https://api.sparkpost.com/api/v1/sending-domains/$SUB_DOMAIN/verify")

# ------------- NGINX ----------------
mkdir -p nginx

# オレオレ証明書を準備、実際の証明書はCloudFlareが提供するため、特に問題ない
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout nginx/$SUB_DOMAIN.key -out nginx/$SUB_DOMAIN.crt \
  -subj "/C=GB/ST=Tokyo/L=Tokyo/O=Global Security/OU=IT Department/CN=$SUB_DOMAIN"

cat <<'EOF'>nginx/nginx.conf
user  nginx;
worker_processes  1; # 適当にあげてください
error_log  /var/log/nginx/error.log warn;
pid        /var/tmp/nginx.pid;
worker_rlimit_nofile 65535;
events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}
http {
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    tcp_nopush     on;
    tcp_nodelay     on;
    server_tokens   off;

    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_redirect off;
    proxy_buffering off;
    proxy_http_version 1.1;

    server {
        listen 80;
        listen 443 ssl;
        server_name $SUB_DOMAIN;
        ssl_certificate /etc/nginx/$SUB_DOMAIN.crt;
        ssl_certificate_key /etc/nginx/$SUB_DOMAIN.key;
        location / {
            proxy_pass http://172.17.0.1:3000;
        }
        location /api/v1/streaming {
            proxy_pass http://172.17.0.1:4000;
        }
    }
}
EOF
sed -i 's/\$SUB_DOMAIN/'$SUB_DOMAIN'/g' nginx/nginx.conf

# コンテナを全部立ち上げる
docker-compose up -d

# ログの確認したい方は
# docker-compose logs -f #(ctrl+cで終了）

# -------- INFO -----------

# ここで初めてアクセスできるようになる
echo https://$SUB_DOMAIN/

# 管理者に昇格
echo "以下のコマンドの末にユーザIDを指定して実行すれば管理者に昇格される"
echo docker-compose run --rm web rails mastodon:make_admin USERNAME=

