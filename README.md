# 📡 television

**Telegram MTProxy manager** powered by [telemt](https://github.com/telemt/telemt) — лёгкий Rust-прокси с поддержкой FakeTLS.

> Работает поверх официального `ghcr.io/telemt/telemt:latest` — всегда актуальная версия.

---

## 🚀 Установка (одна команда)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/J-L33T/television/main/install.sh)
```

Скрипт скачает `television` в `/usr/local/bin/` и сразу запустит интерактивный мастер установки.

---

## 📋 Что умеет

- 🔧 **Установка** — настройка порта, FakeTLS домена, протокола; автоустановка Docker
- 👥 **Управление пользователями** — добавить / удалить / вкл/выкл, именованные ссылки
- 🔗 **Proxy-ссылки** — генерирует `tg://proxy?...` с правильным `ee`-секретом
- 🔄 **Обновление** — `docker pull ghcr.io/telemt/telemt:latest` одной кнопкой
- 📊 **Логи** — прямо в TUI
- ⚙️ **Реконфигурация** — смена порта / домена без переустановки

---

## 🖥 TUI

```
══════════════════════════════════════════════════════════════
                  📡  TELEVISION  v0.1.1
══════════════════════════════════════════════════════════════

 STATUS
 ──────────────────────────────────────────────────────────
  Installation         ● Installed
  Proxy                ● Active
  IP                   1.2.3.4
  Port                 443
  Domain (FakeTLS)     cloudflare.com
  Protocol             tls
  Users                3

 MAIN MENU
 ──────────────────────────────────────────────────────────
  1) Stop proxy
  2) Restart proxy
  3) User management
  4) Show proxy links
  5) Update telemt
  6) View logs
  7) Reconfigure

  0) Full uninstall

 [?] Option:
```

---

## ⚡ CLI режим

```bash
television install
television start / stop / restart
television status
television add-user <name>
television list-users
television links
television update
television logs
```

---

## 🔧 Технические детали

- Docker образ: `ghcr.io/telemt/telemt:latest` (официальный, всегда свежий)
- Конфиг: `/opt/television/telemt.toml` (официальный формат telemt)
- Секреты: `/opt/television/secrets.conf`
- Режим сети: `host` (нет NAT, нет потерь порта)

---

## 📄 License

MIT — [J-L33T/television](https://github.com/J-L33T/television)
