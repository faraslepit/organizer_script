#!/usr/bin/env bash
# ==========================================================
# File Organizer
# Сортирует файлы по расширениям, поддерживает dry-run и undo.
# ==========================================================

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
JOURNAL_FILE=".organizer_journal.log"

DRY_RUN=false
VERBOSE=false
INCLUDE_HIDDEN=false

COUNT_DIRS=0
COUNT_FILES=0
COUNT_ERRORS=0
COUNT_SKIPPED=0

# Цвета (отключаются, если вывод не в терминал)
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;2m'; YELLOW='\033[0;33m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; RESET=''
fi

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        ERROR) echo -e "${RED}[${ts}] ERROR: ${msg}${RESET}" >&2 ;;
        WARN)  echo -e "${YELLOW}[${ts}] WARN: ${msg}${RESET}" ;;
        INFO)  [[ "$VERBOSE" == true ]] && echo -e "${GREEN}[${ts}] INFO: ${msg}${RESET}" ;;
    esac
    
    # Пишем в журнал только реальные действия
    [[ "$DRY_RUN" != true ]] && echo "[${ts}] ${level}: ${msg}" >> "$JOURNAL_FILE"
}

on_exit() {
    echo -e "\n${GREEN}--- Итоги ---${RESET}"
    echo "Создано/использовано папок: ${COUNT_DIRS}"
    echo "Перемещено файлов: ${COUNT_FILES}"
    echo "Ошибок: ${COUNT_ERRORS}"
    echo "Пропущено (системные/скрытые/скрипт): ${COUNT_SKIPPED}"
}
trap on_exit EXIT

usage() {
    cat <<EOF
Использование: ${SCRIPT_NAME} [ОПЦИИ]
Опции:
  -n, --dry-run   Предпросмотр без перемещения
  -v, --verbose   Подробный вывод
  -h, --hidden    Включить скрытые файлы
  --undo          Откат последнего запуска
  --help          Справка
EOF
    exit 0
}

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--hidden)  INCLUDE_HIDDEN=true; shift ;;
        --undo)
            if [[ ! -f "$JOURNAL_FILE" ]]; then
                echo "Журнал '${JOURNAL_FILE}' не найден. Нечего откатывать." >&2; exit 1
            fi
            echo "Начинаю откат изменений..."
            undo_count=0
            while IFS=$'\t' read -r src dest; do
                [[ -z "$src" || -z "$dest" ]] && continue
                if [[ -f "$dest" ]]; then
                    if mv -f "$dest" "$src" 2>/dev/null; then
                        echo "<- Вернул: ${dest} -> ${src}"
                        undo_count=$((undo_count + 1))
                    else
                        echo "!! Не удалось вернуть: ${dest}" >&2
                    fi
                else
                    echo "?? Файл не найден: ${dest} (возможно, удален вручную)" >&2
                fi
            done < "$JOURNAL_FILE"
            > "$JOURNAL_FILE"
            echo "Откат завершён. Возвращено файлов: ${undo_count}"
            exit 0
            ;;
        --help|-?) usage ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

# Получение расширения файла
get_ext() {
    local filepath="$1"
    local filename
    filename="$(basename "$filepath")"

    # 1. Пропускаем сам скрипт и журнал
    if [[ "$filename" == "$SCRIPT_NAME" || "$filename" == "$JOURNAL_FILE" ]]; then
        return 1
    fi

    # 2. Пропускаем скрытые файлы, если не указан флаг -h
    if [[ "$INCLUDE_HIDDEN" != true && "$filename" == .* ]]; then
        return 1
    fi

    # 3. Определяем расширение
    if [[ "$filename" == *.* ]]; then
        local ext="${filename##*.}"
        echo "$ext" | tr '[:upper:]' '[:lower:]'
        return 0
    else
        echo "no_ext"
        return 0
    fi
}

# Безопасное перемещение
safe_move() {
    local src="$1" target_dir="$2"
    local filename; filename="$(basename "$src")"
    local dest="${target_dir}/${filename}"

    # Обработка коллизий имен
    if [[ -e "$dest" ]]; then
        local name_part="${filename%.*}"
        local ext_part="${filename##*.}"
        
        # Для файлов без расширения
        [[ "$name_part" == "$filename" ]] && ext_part=""

        local counter=1
        while true; do
            if [[ -n "$ext_part" ]]; then
                dest="${target_dir}/${name_part}_${counter}.${ext_part}"
            else
                dest="${target_dir}/${name_part}_${counter}"
            fi
            
            [[ ! -e "$dest" ]] && break
            counter=$((counter + 1))
        done
        log "WARN" "Коллизия имен: ${filename} -> $(basename "$dest")"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] Переместить: ${src} -> ${dest}"
    else
        if mv -- "$src" "$dest" 2>/dev/null; then
            printf '%s\t%s\n' "$src" "$dest" >> "$JOURNAL_FILE"
            return 0
        else
            log "ERROR" "Не удалось переместить: ${src}"
            return 1
        fi
    fi
    return 0
}

main() {
    echo "Запуск организатора файлов..."
    [[ "$DRY_RUN" == true ]] && echo -e "${YELLOW}ВНИМАНИЕ: Режим предпросмотра (файлы не будут перемещены)${RESET}"
    echo "----------------------------------------"

    if [[ ! -w "." ]]; then 
        log "ERROR" "Нет прав на запись в текущую директорию."; exit 1
    fi

    [[ "$DRY_RUN" != true && ! -f "$JOURNAL_FILE" ]] && touch "$JOURNAL_FILE"

    local find_args=(-maxdepth 1 -type f)
    [[ "$INCLUDE_HIDDEN" != true ]] && find_args+=(! -name '.*')

    # Собираем список файлов во временный файл
    local tmpfile
    tmpfile=$(mktemp)
    find . "${find_args[@]}" -print0 > "$tmpfile"

    # Обработка списка
    while IFS= read -r -d '' file; do
        ext=$(get_ext "$file")
        rc=$?
        
        # Если функция вернула ошибку или расширение пустое - пропускаем
        if [[ $rc -ne 0 || -z "$ext" ]]; then
            COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
            continue
        fi

        local target_dir="${ext}_dir"

        if [[ ! -d "$target_dir" ]]; then
            [[ "$DRY_RUN" != true ]] && mkdir -p "$target_dir"
            COUNT_DIRS=$((COUNT_DIRS + 1))
            log "INFO" "Будет создана/использована папка: ${target_dir}"
        fi

        if safe_move "$file" "$target_dir"; then
            COUNT_FILES=$((COUNT_FILES + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"
}

main "$@"


