# alloy.yml

## Где выполняется

`alloy.yml` выполняется на `hosts: all`.

- Целевые узлы: frontend, backend master/slave, monitoring, logging.
- `become: yes`: задачи выполняются с root-правами.
- Alloy отправляет логи в Loki, который настраивается в `logging.yml`.

## Что делает playbook

Playbook разворачивает Grafana Alloy на всех узлах как агент сбора логов:

1. Создает системного пользователя `alloy` и добавляет его в группу `adm`.
2. Проверяет preinstalled бинарник Alloy в box `diplom-ubuntu`.
3. Создает директории конфигурации и данных.
4. Разворачивает `config.alloy` и systemd unit.
5. Дает Alloy права на чтение PHP-FPM и Grafana логов, если они есть.
6. Запускает и включает `alloy.service`.

## Подробно по task'ам

- `Создание пользователя alloy` создает системного пользователя без shell и home directory. Параметры `groups: adm` и `append: yes` добавляют пользователя в группу `adm`, не удаляя другие группы. Это нужно для чтения системных логов.
- `Проверка наличия бинарника Alloy` проверяет `/usr/local/bin/alloy` и сохраняет результат в `alloy_stat`.
- `Проверка бинарника Alloy в box-образе` — `assert`, что `/usr/local/bin/alloy` существует и executable.
- `Создание директорий Alloy` через `loop` создает `/etc/alloy` с владельцем `root:root` и `/var/lib/alloy` с владельцем `alloy:alloy`. Первая директория хранит конфигурацию, вторая — runtime/state данные агента.
- `Развернуть config.alloy` рендерит `templates/alloy/config.alloy.j2` в `/etc/alloy/config.alloy`, владельцем оставляет `root`, группой ставит `alloy`, права `0640`. При изменении вызывает `Restart Alloy`.
- `Развернуть systemd-юнит Alloy` рендерит `templates/alloy/alloy.service.j2` в `/etc/systemd/system/alloy.service` и вызывает `Reload systemd`.
- `Поиск PHP-FPM логов для Alloy` ищет файлы `php*-fpm.log` в `/var/log` и сохраняет список в `php_fpm_log_files`.
- `Разрешить Alloy читать PHP-FPM логи` меняет группу найденных PHP-FPM логов на `adm` и добавляет group-read (`g+r`). Выполняется только если такие логи найдены.
- `Поиск Grafana логов для Alloy` ищет `*.log` в `/var/log/grafana`. `failed_when: false` нужен, потому что директория может отсутствовать на узлах без Grafana.
- `Разрешить Alloy читать Grafana логи` меняет группу найденных Grafana логов на `adm` и добавляет group-read. Выполняется только если файлы найдены.
- `Активация и запуск Alloy` запускает `alloy.service`, включает автозапуск и делает `daemon_reload`.

## Handlers

- `Restart Alloy` перезапускает `alloy.service` после установки бинарника или изменения конфигурации.
- `Reload systemd` перечитывает unit-файлы после изменения `alloy.service`.

## Используемые модули

Модули `user`, `stat`, `shell`, `file`, `template`, `systemd` описаны в `ha_shared.md`.

### `ansible.builtin.find`

Ищет файлы на удаленном хосте по пути, шаблону и типу. В этом playbook'е используется для поиска PHP-FPM и Grafana логов, которым нужно выдать права на чтение для Alloy.

## Связанные шаблоны и файлы

- `ansible/templates/alloy/config.alloy.j2`
- `ansible/templates/alloy/alloy.service.j2`
- `/usr/local/bin/alloy`
- `/etc/alloy/config.alloy`
- `/var/lib/alloy`
- `/var/log/php*-fpm.log`
- `/var/log/grafana/*.log`
