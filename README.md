4. Установка Nginx и подготовка origin-сервера
На сервере origin должны работать: Nginx на 80/443, сайт-заглушка для DOMAIN_1, certbot-сертификат для
DOMAIN_1 и Xray inbound на локальном порту 127.0.0.1:2090.
4.1. Установка пакетов на Ubuntu
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx curl dnsutils
sudo systemctl enable --now nginx
sudo systemctl status nginx --no-pager
4.2. Проверка текущих конфигов Nginx
sudo nginx -t
sudo nginx -T | less
sudo nginx -T | grep -nE "server_name|DOMAIN_1|DOMAIN_2|api/v1/sync|proxy_pass|2090" -C 4
sudo ss -lntp | grep -E ':80|:443|:2090'
4.3. Выпуск сертификата для DOMAIN_1 на origin
DNS для DOMAIN_1 должен указывать A-записью на SERVER_IP. Это сертификат для участка Yandex CDN ->
origin.
# DNS должен быть примерно таким:
# DOMAIN_1. A SERVER_IP
dig +short DOMAIN_1 @1.1.1.1
# Выпуск через nginx-плагин
sudo certbot --nginx -d DOMAIN_1
# Альтернатива, если нужно standalone:
# sudo systemctl stop nginx
# sudo certbot certonly --standalone -d DOMAIN_1
# sudo systemctl start nginx
4.4. Создание сайта-заглушки для DOMAIN_1
sudo mkdir -p /var/www/DOMAIN_1
sudo tee /var/www/DOMAIN_1/index.html > /dev/null <<'EOF'
<!doctype html>
<html lang="en">
<head>
 <meta charset="utf-8">
 <meta name="viewport" content="width=device-width, initial-scale=1">
 <title>Service Portal</title>
 <style>
 body { font-family: Arial, sans-serif; background:#0f172a; color:#e5e7eb; margin:0; }
 .wrap { max-width: 760px; margin: 12vh auto; padding: 32px; }
 .card { background:#111827; border:1px solid #374151; border-radius:16px; padding:28px; }
 input, button { padding:12px; border-radius:8px; border:1px solid #4b5563; margin:6px 0; }
 input { width:100%; background:#030712; color:#e5e7eb; }
 button { background:#2563eb; color:white; cursor:pointer; }
 </style>
</head>
<body>
 <div class="wrap"><div class="card">
 <h1>Service Portal</h1>
 <p>Sign in to continue.</p>
 <form action="/login" method="post">
 <input name="user" placeholder="Username">
 <input name="password" placeholder="Password" type="password">
 <button type="submit">Sign in</button>
 </form>
 </div></div>
</body>
</html>
EOF
sudo chown -R www-data:www-data /var/www/DOMAIN_1
5. Конфигурация Nginx для DOMAIN_1
Создайте отдельный vhost под DOMAIN_1. Он отдает заглушку на обычные URL и проксирует /api/v1/sync в
локальный Xray inbound.
sudo nano /etc/nginx/sites-available/DOMAIN_1
server {
 listen 80;
 listen [::]:80;
 server_name DOMAIN_1;
 return 301 https://$host$request_uri;
}
server {
 listen 443 ssl;
 listen [::]:443 ssl;
 server_name DOMAIN_1;
 ssl_certificate /etc/letsencrypt/live/DOMAIN_1/fullchain.pem;
 ssl_certificate_key /etc/letsencrypt/live/DOMAIN_1/privkey.pem;
 ssl_protocols TLSv1.2 TLSv1.3;
 root /var/www/DOMAIN_1;
 index index.html;
 location = / {
 try_files /index.html =404;
 }
 location = /login {
 default_type application/json;
 add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
always;
 return 401 '{"status":"error","message":"Invalid username or password"}';
 }
 location = /favicon.ico {
 return 204;
 }
 location = /robots.txt {
 default_type text/plain;
 return 200 "User-agent: *\nDisallow:\n";
 }
 location = /debug-xhttp {
 default_type text/plain;
 return 200 "host=$host
http_host=$http_host
method=$request_method
uri=$request_uri
x_forwarded_proto=$http_x_forwarded_proto
user_agent=$http_user_agent
";
 }
 location = /api/v1/sync {
 proxy_pass http://127.0.0.1:2090;
 proxy_http_version 1.1;
 proxy_set_header Host DOMAIN_1;
 proxy_set_header X-Real-IP $remote_addr;
 proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
 proxy_set_header X-Forwarded-Proto https;
 proxy_buffering off;
 proxy_request_buffering off;
 proxy_cache off;
 proxy_read_timeout 3600s;
 proxy_send_timeout 3600s;
 client_max_body_size 0;
 }
 location ^~ /api/v1/sync/ {
 proxy_pass http://127.0.0.1:2090;
 proxy_http_version 1.1;
 proxy_set_header Host DOMAIN_1;
 proxy_set_header X-Real-IP $remote_addr;
 proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
 proxy_set_header X-Forwarded-Proto https;
 proxy_buffering off;
 proxy_request_buffering off;
 proxy_cache off;
 proxy_read_timeout 3600s;
 proxy_send_timeout 3600s;
 client_max_body_size 0;
 }
 location / {
 try_files $uri $uri/ /index.html;
 }
}
5.1. Включение vhost и reload
sudo ln -s /etc/nginx/sites-available/DOMAIN_1 /etc/nginx/sites-enabled/DOMAIN_1
sudo nginx -t
sudo systemctl reload nginx
5.2. Если копируете существующую заглушку
sudo mkdir -p /var/www/DOMAIN_1
sudo cp -a /var/www/EXISTING_MASK_SITE/. /var/www/DOMAIN_1/
sudo chown -R www-data:www-data /var/www/DOMAIN_1
sudo nginx -t && sudo systemctl reload nginx

