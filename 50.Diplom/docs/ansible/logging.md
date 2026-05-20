# logging.yml

## Где выполняется

`logging.yml` выполняется на группе `logging`.

- Хост: `192.168.56.40`.
- `become: yes`: задачи выполняются с root-правами.
- Loki принимает логи на порту `3100`; firewall-правила для этого порта описаны в `UFW.md`.

## Что делает playbook

Playbook разворачивает Grafana Loki как централизованное хранилище логов:

1. Создает системного пользователя `loki`.
2. Проверяет preinstalled бинарник Loki в box `diplom-ubuntu`.
3. Создает директории конфигурации, данных и логов.
4. Разворачивает `loki.yml` и systemd unit.
5. Запускает и включает `loki.service`.

## Подробно по task'ам

- `Создание пользователя loki` создает системного пользователя без shell и home directory. От него работает сервис Loki.
- `Проверка наличия бинарника Loki` проверяет `/usr/local/bin/loki` и сохраняет результат в `loki_stat`, чтобы установка была идемпотентной.
- `Проверка бинарника Loki в box-образе` — `assert`, что `/usr/local/bin/loki` существует и executable.
- `Создание директорий Loki` создает `/etc/loki`, `/var/lib/loki`, `/var/lib/loki/compactor`, `/var/log/loki` с владельцем `loki:loki`. Эти каталоги нужны для конфига, хранения индексов/чанков, compactor и логов сервиса.
- `Создать log-файл Loki для централизованного сбора` создает `/var/log/loki/loki.log`, владельцем делает `loki`, группой `adm`, правами `0640`. Группа `adm` важна, чтобы агент сбора логов мог читать файл.
- `Развернуть loki.yml` рендерит `templates/loki/loki.yml.j2` в `/etc/loki/loki.yml` и вызывает `Restart Loki`.
- `Развернуть systemd-юнит Loki` рендерит `templates/loki/loki.service.j2` в `/etc/systemd/system/loki.service` и вызывает `Reload systemd`.
- `Активация и запуск Loki` запускает `loki.service`, включает автозапуск и выполняет `daemon_reload`.

## Handlers

- `Restart Loki` перезапускает `loki.service` и делает `daemon_reload`, когда меняется бинарник или конфигурация.
- `Reload systemd` перечитывает systemd unit-файлы после изменения `loki.service`.

## Используемые модули

Все модули этого playbook'а уже описаны ранее:

- `user`, `stat`, `shell`, `file`, `template`, `systemd` — см. `ha_shared.md`.

## Связанные шаблоны и файлы

- `ansible/templates/loki/loki.yml.j2`
- `ansible/templates/loki/loki.service.j2`
- `/usr/local/bin/loki`
- `/etc/loki/loki.yml`
- `/var/lib/loki`
- `/var/lib/loki/compactor`
- `/var/log/loki/loki.log`
