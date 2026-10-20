# Remnawave Node Installer

Интерактивный идемпотентный установщик и обновлятор официальной Docker-ноды Remnawave.

## Возможности

- спрашивает `SECRET_KEY` скрытым вводом;
- позволяет выбрать порт, каталог и Docker-образ/тег;
- всегда выполняет `docker compose pull`, поэтому тег `latest` обновляется до свежего образа;
- проверяет Base64 и обязательные поля секрета;
- не записывает секрет в репозиторий или журнал;
- создаёт резервную копию существующих `.env` и `docker-compose.yml`;
- при ошибке обновления возвращает предыдущую конфигурацию;
- добавляет правило UFW только тогда, когда UFW активен;
- повторный запуск безопасно обновляет существующую установку.

## Быстрая установка

Запустите на Ubuntu/Debian-сервере от `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/egMRL/remnawave-node-installer/main/install.sh | bash
```

Или сначала скачайте и проверьте файл:

```bash
curl -fsSLO https://raw.githubusercontent.com/egMRL/remnawave-node-installer/main/install.sh
less install.sh
sudo bash install.sh
```

Установщик спросит:

1. каталог установки — по умолчанию `/opt/remnanode`;
2. порт ноды — по умолчанию `2222`;
3. образ — по умолчанию `remnawave/node:latest`;
4. `SECRET_KEY` из карточки ноды в панели — ввод не отображается;
5. нужно ли разрешить порт в активном UFW.

Имя ноды задаётся в панели Remnawave. На сервер передаётся выданный этой ноде `SECRET_KEY`.

## Обновление

Запустите ту же команду ещё раз. Установщик предложит оставить текущий секрет, создаст резервную копию, загрузит свежий образ и пересоздаст контейнер.

## Неинтерактивный запуск

Безопаснее передавать секрет через файл с правами `600`:

```bash
install -m 600 /dev/null /root/remnawave-secret
nano /root/remnawave-secret

REMNAWAVE_SECRET_KEY_FILE=/root/remnawave-secret \
REMNAWAVE_NODE_PORT=2222 \
REMNAWAVE_ASSUME_YES=yes \
bash install.sh
```

Доступны переменные:

| Переменная | Значение по умолчанию |
|---|---|
| `REMNAWAVE_SECRET_KEY_FILE` | — |
| `REMNAWAVE_SECRET_KEY` | — (менее безопасный вариант) |
| `REMNAWAVE_NODE_PORT` | `2222` |
| `REMNAWAVE_NODE_IMAGE` | `remnawave/node:latest` |
| `REMNAWAVE_INSTALL_DIR` | `/opt/remnanode` |
| `REMNAWAVE_OPEN_UFW` | `yes` |
| `REMNAWAVE_ASSUME_YES` | `no` |

## Диагностика

```bash
cd /opt/remnanode
docker compose ps
docker compose logs -f --tail=100
ss -lntp | grep ':2222'
```

Порт ноды также должен быть разрешён во внешнем firewall хостинг-провайдера и доступен с сервера панели.

## Безопасность

- `.env` и каталог установки получают ограниченные права доступа;
- секрет не передаётся аргументом командной строки;
- не публикуйте `SECRET_KEY` в GitHub, чатах и скриншотах;
- если ключ был раскрыт, перевыпустите его в панели и повторно запустите установщик.

## Требования

- Linux на базе Debian/Ubuntu;
- запуск от `root`;
- исходящий HTTPS-доступ к Docker Hub и `get.docker.com`.

## Лицензия

MIT
