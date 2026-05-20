# restic_init.yml

## Где выполняется

`restic_init.yml` выполняется на `hosts: frontend:backend`.

- Целевые группы: `frontend`, `backend_master`, `backend_slave`.
- `become: yes`: задачи выполняются с root-правами.
- `serial: 1`: хосты обрабатываются по одному. Это снижает одновременную нагрузку на Rest Server и упрощает первичную инициализацию репозиториев.
- Используемые переменные: `restic_label`, `restic_password`, `restic_server_user`, `restic_server_password`.

## Что делает playbook

Playbook выполняет bootstrap Restic после запуска Rest Server:

1. Дожидается доступности Rest Server на `10.10.10.40:8000`.
2. Инициализирует Restic-репозиторий для текущего узла, если он еще не создан.
3. Проверяет количество snapshot'ов.
4. Запускает первый backup, если репозиторий пустой.

## Подробно по task'ам

- `Ожидание Rest Server` использует `wait_for`, чтобы дождаться TCP-порта `8000` на `10.10.10.40`. Timeout `120` секунд дает сервису время подняться после `ha_shared.yml`.
- `Инициализация Restic-репозитория` сначала выполняет `restic snapshots`, а если репозиторий еще не существует или недоступен как инициализированный, выполняет `restic init`. Переменная окружения `RESTIC_PASSWORD_FILE=/etc/restic_password` указывает Restic на файл пароля. `changed_when` помечает задачу измененной только при создании нового репозитория. `failed_when: restic_init.rc != 0` делает ошибку инициализации критичной для этого bootstrap-playbook'а.
- `Проверка количества snapshot в Restic-репозитории` получает JSON-вывод `restic snapshots --json` и через Python печатает количество snapshot'ов. Результат сохраняется в `restic_snapshot_count`. `changed_when: false` делает задачу чистой проверкой.
- `Запуск первого backup для пустого Restic-репозитория` запускает `restic-backup-{{ restic_label }}.service`, если количество snapshot'ов равно нулю. Это гарантирует, что после bootstrap в репозитории появится первый backup, а дальнейшие backup'и будут выполняться timer'ами из `front.yml` и `back.yml`.

## Handlers

В этом playbook'е handlers отсутствуют. Он вызывает уже существующие systemd service units Restic, созданные в `front.yml` и `back.yml`.

## Используемые модули

Все модули этого playbook'а уже описаны ранее:

- `wait_for` — см. `back.md`.
- `shell` — см. `ha_shared.md`.
- `systemd` — см. `ha_shared.md`.

## Связанные шаблоны и файлы

Playbook напрямую не рендерит шаблоны, но зависит от файлов, созданных другими playbook'ами:

- `/etc/restic_password`
- `/etc/systemd/system/restic-backup-frontend.service`
- `/etc/systemd/system/restic-backup-backend_master.service`
- `/etc/systemd/system/restic-backup-backend_slave.service`
- Restic endpoint: `rest:http://{{ restic_server_user }}:{{ restic_server_password }}@10.10.10.40:8000/{{ restic_label }}`
