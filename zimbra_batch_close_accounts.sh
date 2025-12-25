#!/bin/bash
#
# Copyright (c) 2025 Ivan V. Belikov
#
# Лицензия: MIT License (см. файл LICENSE)
# https://opensource.org/licenses/MIT
# ------------------------------------------------------------
# Скрипт ежедневного закрытия (status=closed) неактивных ящиков Zimbra.
#
# Что делает:
# 1) Читает CSV /opt/zimbra/accounts_with_date.csv
#    Формат строк: Email;Дата создания;Статус;Notes;Последний вход;DisplayName
# 2) Читает файл исключений /opt/zimbra/logs/tmp/actual_email TXT.txt
#    - 1-я строка заголовок (игнорируется)
#    - возможны пустые строки (игнорируются)
#    - в строке может быть несколько email с любыми разделителями
#    - все найденные email попадают в список EXCLUDES
# 3) Для каждого ящика со статусом "active":
#    - пропускает, если email в EXCLUDES
#    - пропускает, если notes содержит never_disable
#    - если в Notes найдена дата:
#         * закрывает, если дата <= сегодняшнего дня
#         * если дата в будущем — полностью игнорирует ящик (не проверяет неактивность)
#    - если даты в Notes нет:
#         * закрывает, если last_login старше 6 месяцев
#         * если last_login пустой — закрывает, если created старше 6 месяцев
# 4) В режиме --dry-run только логирует действие без реального изменения статуса.
#
# Логи:
#   /opt/zimbra/logs/zimbra_disable_today.log
#   /opt/zimbra/logs/zimbra_disable_today.dryrun.log
#   /opt/zimbra/logs/zimbra_disable_debug.log
#
# Запуск:
#   ./zimbra_disable_today.sh
#   ./zimbra_disable_today.sh --dry-run
#   ./zimbra_disable_today.sh -n
# ------------------------------------------------------------

# === ОКРУЖЕНИЕ ===
export PATH="/opt/zimbra/bin:/usr/bin:/bin:/opt/zimbra/common/bin"
export LANG="ru_RU.UTF-8"
export LC_ALL="ru_RU.UTF-8"

# === АРГУМЕНТЫ ===
DRY_RUN=0
case "$1" in
  -n|--dry-run) DRY_RUN=1 ;;
  "" ) ;;
  * ) echo "Usage: $0 [--dry-run|-n]"; exit 1 ;;
esac

# === ПУТИ ===
INPUT_FILE="/opt/zimbra/accounts_with_date.csv"
LOG_FILE="/opt/zimbra/logs/zimbra_disable_today.log"
[[ "$DRY_RUN" -eq 1 ]] && LOG_FILE="/opt/zimbra/logs/zimbra_disable_today.dryrun.log"
DEBUG_LOG="/opt/zimbra/logs/zimbra_disable_debug.log"

# Файл исключений (важно: в имени есть пробелы)
EXCLUDE_FILE="/opt/zimbra/logs/tmp/actual_email TXT.txt"

# === ПОДГОТОВКА ЛОГОВ ===
: > "$LOG_FILE"
: > "$DEBUG_LOG"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Старт. Режим: $([[ $DRY_RUN -eq 1 ]] && echo DRY-RUN || echo APPLY). Файл: $INPUT_FILE" >> "$DEBUG_LOG"

# === ТЕКУЩЕЕ ВРЕМЯ ===
now_epoch=$(date +%s)
six_months_ago=$(date -d "-6 months" +%s)
today_end_epoch=$(date -d "today 23:59:59" +%s)

# === ИСКЛЮЧЕНИЯ ===
declare -A EXCLUDES

load_exclusions() {
  EXCLUDES=()

  if [[ ! -f "$EXCLUDE_FILE" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: файл исключений не найден: $EXCLUDE_FILE" >> "$DEBUG_LOG"
    return 0
  fi

  # Читаем со 2-й строки (пропускаем заголовок)
  while IFS= read -r raw_line; do
    # Вытаскиваем ВСЕ email-ы из строки
    emails=$(echo "$raw_line" | grep -Eio '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}')

    if [[ -n "$emails" ]]; then
      while IFS= read -r e; do
        e=$(echo "$e" | tr '[:upper:]' '[:lower:]')
        EXCLUDES["$e"]=1
      done <<< "$emails"
    fi
    # пустые строки ничего не дадут и просто игнорируются
  done < <(tail -n +2 "$EXCLUDE_FILE")

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Загружено исключений: ${#EXCLUDES[@]}" >> "$DEBUG_LOG"
}

load_exclusions

# === ФУНКЦИИ ===

# Преобразование Zimbra-штампа 20220614184815.765Z (или 20220614184815Z/без .xxx) в epoch
to_epoch() {
  local zdate="$1"
  local clean_date
  clean_date=$(echo "$zdate" | sed -E 's/\.[0-9]+Z$|Z$//')
  if [[ "$clean_date" =~ ^[0-9]{14}$ ]]; then
    date -d "${clean_date:0:4}-${clean_date:4:2}-${clean_date:6:2} ${clean_date:8:2}:${clean_date:10:2}:${clean_date:12:2}" +%s 2>/dev/null
  else
    echo 0
  fi
}

# Вывод ДД.ММ.ГГГГ из Zimbra-штампа
format_date_pretty() {
  local raw="$1"
  local clean
  clean=$(echo "$raw" | sed -E 's/\.[0-9]+Z$|Z$//')
  if [[ "$clean" =~ ^[0-9]{14}$ ]]; then
    date -d "${clean:0:4}-${clean:4:2}-${clean:6:2}" +"%d.%m.%Y"
  else
    echo "$raw"
  fi
}

# Извлечь дату из Notes (23.10.2024 / 23,10,2024 / 23 10 2024 / 23102024), вернуть как ДД.ММ.ГГГГ
extract_date_from_notes() {
  local s="$1"
  local found
  found=$(echo "$s" | grep -Eo '([0-9]{2})[[:space:].,/_-]?([0-9]{2})[[:space:].,/_-]?([0-9]{4})' | head -n1)
  if [[ -n "$found" ]]; then
    echo "$found" | sed -E 's/^([0-9]{2})[[:space:].,/_-]?([0-9]{2})[[:space:].,/_-]?([0-9]{4})$/\1.\2.\3/'
  fi
}

# Преобразовать ДД.ММ.ГГГГ в epoch конца суток
notes_date_to_epoch_end() {
  local pretty="$1"
  if [[ "$pretty" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})$ ]]; then
    local dd="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}" yyyy="${BASH_REMATCH[3]}"
    date -d "$yyyy-$mm-$dd 23:59:59" +%s 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Закрыть учётку (или только сымитировать)
close_account() {
  local email="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DRY-RUN] zmprov ma $email zimbraAccountStatus closed" >> "$DEBUG_LOG"
    return 0
  else
    zmprov ma "$email" zimbraAccountStatus closed
    return $?
  fi
}

# Записать действие в основной лог (с DRY-RUN пометкой при необходимости)
log_action() {
  local line="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $line" >> "$LOG_FILE"
  else
    echo "$line" >> "$LOG_FILE"
  fi
}

# === ПРОВЕРКИ ===
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Файл не найден: $INPUT_FILE" >> "$DEBUG_LOG"
  exit 1
fi

# === ОБРАБОТКА CSV ===
tail -n +2 "$INPUT_FILE" | while IFS=";" read -r email created status notes last_login display_name; do
  [[ -z "$email" || "$status" != "active" ]] && continue

  # --- Пропуск, если email в списке исключений ---
  email_lc=$(echo "$email" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -n "${EXCLUDES[$email_lc]}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Пропуск (в файле исключений): $email" >> "$DEBUG_LOG"
    continue
  fi

  # Исключение по метке never_disable
  if echo "$notes" | grep -iq "never_disable"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Пропуск (never_disable): $email" >> "$DEBUG_LOG"
    continue
  fi

  # 1) Если в Notes есть дата: блокируем только если дата <= сегодня; если дата будущая — ПОЛНОСТЬЮ игнорируем аккаунт
  notes_date=$(extract_date_from_notes "$notes")
  if [[ -n "$notes_date" ]]; then
    nd_epoch=$(notes_date_to_epoch_end "$notes_date")
    if (( nd_epoch > 0 && nd_epoch <= today_end_epoch )); then
      if close_account "$email"; then
        log_action "$email Увольнение $notes_date"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Закрыт по Notes (<= сегодня): $email ($notes_date)" >> "$DEBUG_LOG"
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Ошибка закрытия по Notes: $email ($notes_date)" >> "$DEBUG_LOG"
      fi
      continue
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Пропуск по Notes (будущая дата): $email ($notes_date)" >> "$DEBUG_LOG"
      continue  # будущая дата — вообще не трогаем
    fi
  fi

  # 2) Если даты в Notes нет: проверяем неактивность > 6 месяцев
  if [[ -n "$last_login" ]]; then
    last_login_epoch=$(to_epoch "$last_login")
    if (( last_login_epoch > 0 && last_login_epoch < six_months_ago )); then
      pretty=$(format_date_pretty "$last_login")
      if close_account "$email"; then
        log_action "$email неактивна с $pretty"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Закрыт по last_login ($pretty): $email" >> "$DEBUG_LOG"
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Ошибка закрытия по last_login: $email" >> "$DEBUG_LOG"
      fi
      continue
    fi
  elif [[ -n "$created" ]]; then
    created_epoch=$(to_epoch "$created")
    if (( created_epoch > 0 && created_epoch < six_months_ago )); then
      pretty=$(format_date_pretty "$created")
      if close_account "$email"; then
        log_action "$email неактивна с $pretty"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Закрыт по created ($pretty): $email" >> "$DEBUG_LOG"
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Ошибка закрытия по created: $email" >> "$DEBUG_LOG"
      fi
      continue
    fi
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Пропуск (условия не выполнены): $email" >> "$DEBUG_LOG"
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Завершено. Лог действий: $LOG_FILE" >> "$DEBUG_LOG"
