# 📡 television

**Telegram MTProxy manager** powered by [telemt](https://github.com/telemt/telemt) — Rust-прокси с поддержкой FakeTLS и Middle Proxy режима.

> Работает поверх официального `ghcr.io/telemt/telemt:latest` — всегда актуальная версия.

---

## 🚀 Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/J-L33T/television/main/install.sh)
```

Скрипт установит `television` в `/usr/local/bin/` и откроет интерактивное меню. После установки достаточно просто набрать:

```bash
television
```

---

## 📋 Возможности

- 🔧 **Установка** — настройка порта, FakeTLS домена, протокола; автоустановка Docker
- 👥 **Управление пользователями** — добавить / удалить / включить / выключить
- 🔗 **Proxy-ссылки** — генерирует `tg://proxy?...` с правильным `ee`-секретом
- 📊 **Статистика** — сессии, уникальные IP, uptime
- 📋 **Логи** — фильтрованный вывод прямо в TUI
- 🔄 **Обновление** — `docker pull` одной кнопкой
- ⚙️ **Реконфигурация** — смена порта / домена без переустановки
- 🔁 **Автозапуск** — systemd-сервис, прокси стартует при перезагрузке сервера

---

## 🖥 TUI

```
╔══════════════════════════════════════════════════════════════════╗
║                      TELEVISION  v0.2.0                         ║
║              Telegram MTProxy - Rust/tokio - J-L33T             ║
╠══════════════════════════════════════════════════════════════════╣
║  Engine    telemt :latest  Status: ● RUNNING                    ║
║  IP:Port   1.2.3.4:8443                                         ║
║  Domain    cloudflare.com                                        ║
║  Secrets   2 active                                             ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║                         MAIN MENU                               ║
╠══════════════════════════════════════════════════════════════════╣

  [1]  Proxy Management  (start / stop / restart)
  [2]  Secret Management (add / remove / toggle)
  [3]  Share Links
  [4]  Traffic & Stats
  [5]  Logs
  [6]  Settings          (port / domain / reconfigure)
  [7]  Update telemt

  [s]  Install/reinstall 'television' command
  [u]  Uninstall
  [0]  Exit

╚══════════════════════════════════════════════════════════════════╝
```

---

## ⚡ CLI режим

```bash
television install
television start / stop / restart
television status
television logs
television stats
television add-user <name>
television list-users
television links
television update
television self-install
```

---

## 🔧 Технические детали

| Параметр | Значение |
|---|---|
| Docker образ | `ghcr.io/telemt/telemt:latest` |
| Конфиг | `/opt/television/config.toml` |
| Секреты | `/opt/television/secrets.conf` |
| Настройки | `/opt/television/settings.conf` |
| Автозапуск | `systemd` — `television.service` |
| Режим прокси | Middle Proxy (полное подключение к серверам Telegram) |
| Маскировка | FakeTLS — трафик выглядит как обычный HTTPS |

---

## 📄 License

MIT — [J-L33T/television](https://github.com/J-L33T/television)
