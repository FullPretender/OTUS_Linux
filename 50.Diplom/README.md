# OTUS Linux Diploma — отказоустойчивый WordPress-стенд

Демонстрационная инфраструктура на **5 Vagrant VM** (VirtualBox): HTTPS load balancer, два WordPress backend с MySQL-репликацией, общее состояние на узле `logging`, мониторинг (Prometheus/Grafana/Alertmanager), централизованные логи (Loki + Grafana Alloy) и backup (Restic).

Демо-приложение — **лента мемов** (плагин `demo-forum`, тема `demo-forum-theme`); технические имена файлов сохранены с ранней версии проекта.

## Быстрый старт

**Требования:** VirtualBox, Vagrant, box `diplom-ubuntu`, Ansible с коллекциями `community.mysql` и `ansible.posix`.

```bash
# На хосте
echo '192.168.56.10 lab.diplom.com' | sudo tee -a /etc/hosts

cd /path/to/50.Diplom
vagrant up
vagrant provision logging   # полный Ansible site.yml (если provision не отработал при up)
```

**Проверка:** откройте https://lab.diplom.com/ (самоподписанный TLS — `-k` в curl).

## URL и SSH

| Сервис | URL |
|--------|-----|
| WordPress | https://lab.diplom.com/ |
| Grafana | https://lab.diplom.com/grafana/ |
| Prometheus | https://lab.diplom.com/prometheus/ |
| Alertmanager | https://lab.diplom.com/alertmanager/ |

| VM | SSH (с хоста) |
|----|----------------|
| frontend | `vagrant ssh frontend` или `localhost:2201` |
| backend-1 | `:2202` |
| backend-2 | `:2203` |
| monitoring | `:2204` |
| logging | `:2205` |

Сервисная сеть: `10.10.10.0/24`. Management (Ansible): `192.168.56.0/24`.

## Секреты и учётные записи

Пароли (БД, Restic, Grafana, SMTP Alertmanager) хранятся в **Ansible Vault**:

- `ansible/group_vars/all/vault.yml` (зашифрован)
- ссылки в `ansible/group_vars/all/vars.yml`
- пароль vault: `ansible/.vault_pass` (используется Vagrant provisioner)

Просмотр: `ansible-vault view ansible/group_vars/all/vault.yml --vault-password-file ansible/.vault_pass`

Публичные настройки (без секретов): `ansible/hosts.ini`. Логин WordPress admin: `admin` (пароль — из vault/seed, см. документацию).

## Документация

| Документ | Назначение |
|----------|------------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Архитектура, потоки запросов, HA, шаблоны, отказы |
| [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) | Пошаговый сценарий защиты |
| [docs/ansible/](docs/ansible/) | Справочник по каждому Ansible playbook ([индекс](docs/ansible/README.md)) |
| [scripts/ha_posts_test.sh](scripts/ha_posts_test.sh) | Автоматический HA-тест (21 шаг) |
| [Техническое задание.txt](Техническое%20задание.txt) | Исходные требования |

## Автоматический HA-тест

После развёртывания стенда:

```bash
./scripts/ha_posts_test.sh
```

Скрипт проверяет сохранность постов при `vagrant halt`/`destroy` backend-ов и восстановление из Restic. Подробности — в [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) и [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Ограничения стенда

- Узел **`logging`** в демо — persistent shared-state (HAProxy `:6033`, NFS `wp-content`, Rest Server, Loki); его не разрушают в основном сценарии защиты.
- **`wp-ha-db-sync`** выравнивает БД по `MAX(ID)` в `wp_posts` — best-effort, не замена GTID/auto-failover MySQL.
- Box **`diplom-ubuntu`**: бинарники observability и Rest Server предустановлены в образе; сборка box описана контрактом в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), исходники сборки вне этого репозитория.

## Структура репозитория

```
50.Diplom/
├── Vagrantfile
├── ansible/          # playbooks, templates, inventory, vault
├── docs/
├── scripts/
└── Техническое задание.txt
```
