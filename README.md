git clone bash <(curl -s https://raw.githubusercontent.com/multi81/remnawave-installer/main/install.sh)

🔥 Что получится

Скрипт спросит:

Panel domain:
Subscription domain:

И сам:
поставит Docker
поставит Caddy
создаст env
поднимет Remnawave
выдаст SSL
настроит reverse proxy

⚠️ ОБЯЗАТЕЛЬНО
До запуска:
DNS A-записи должны указывать на сервер
Например:
Type	Name	Value
A	panel	IP_СЕРВЕРА
A	sub	IP_СЕРВЕРА
