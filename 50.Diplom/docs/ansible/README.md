# Справочник Ansible playbook-ов

| Playbook | Документация |
|----------|----------------|
| `site.yml` | [site.md](site.md) |
| `ha_shared.yml` | [ha_shared.md](ha_shared.md) |
| `back.yml` | [back.md](back.md) |
| `front.yml` | [front.md](front.md) |
| `logging.yml` | [logging.md](logging.md) |
| `monitoring.yml` | [monitoring.md](monitoring.md) |
| `alloy.yml` | [alloy.md](alloy.md) |
| `restic_init.yml` | [restic_init.md](restic_init.md) |
| `UFW.yml` | [UFW.md](UFW.md) |

Порядок импорта в `site.yml`: `ha_shared` → `back` → `front` → `logging` → `monitoring` → `alloy` → `restic_init` → `UFW`.

Обзор архитектуры: [../ARCHITECTURE.md](../ARCHITECTURE.md).
