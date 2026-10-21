#!/usr/bin/env bash
# Limpeza segura para macOS — alternativa leve ao CleanMyMac.
# Uso: ./cleanup-mac.sh [--dry-run] [--yes] [--yes-all|--full] [--help]

set -euo pipefail

DRY_RUN=0
DRY_RUN_VERBOSE=0
ASSUME_YES=0
YES_ALL=0
SKIP_ORPHANS=0
CACHES_ONLY=0
CACHES_SAFE=0
ORPHANS_SENSITIVE=0
MENU_MODE=0
MENU_CONFIRMED=0
MENU_RISKY_OK=0
MENU_EST_TOTAL=0
MENU_FLASH_MSG=""
MENU_FLASH_WARN=0
CLI_OPTS=0
FREED_BYTES=0
USER_CACHES_FULL=0
ORPHAN_LIST_PATH=""

# Etapas selecionadas no menu (modo interativo)
STEP_TRASH=0
STEP_ORPHANS=0
STEP_ORPHANS_SENSITIVE=0
STEP_CACHES_FULL=0
STEP_CACHES_SAFE=0
STEP_LOGS=0
STEP_XCODE=0
STEP_DEVTOOLS=0
STEP_SYSTEM_SUDO=0
STEP_MEMORY_PURGE=0

# Preservar entradas em ~/Library/Caches (nome exato da subpasta). Ex.: "com.apple.Safari"
CLEANUP_CACHE_SKIP=()

# --caches-safe: só limpa estes itens dentro de ~/Library/Caches
CACHES_SAFE_ENTRIES=(
  Homebrew
  npm
  pip
  Yarn
  com.google.Chrome
  com.google.Chrome.helper
  org.mozilla.firefox
  company.thebrowser.Browser
  com.apple.iconservices.store
)

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

UI_PANEL_INNER=56

repeat_char() {
  local ch=$1 n=$2
  if (( n <= 0 )); then
    return
  fi
  printf "%${n}s" '' | tr ' ' "$ch"
}

ui_pad_in_box() {
  local text=$1
  local width=$2
  local len=${#text}
  local left=$(( (width - len) / 2 ))
  (( left < 0 )) && left=0
  local right=$(( width - len - left ))
  printf "%*s%s%*s" "$left" "" "$text" "$right" ""
}

# Saída formatada (%b interpreta escapes ANSI nas variáveis de cor)
ui_out() {
  printf '%b\n' "$*"
}

ui_clear_screen() {
  [[ -t 1 ]] || return 0
  if command -v clear >/dev/null 2>&1; then
    clear
  else
    printf '\033[2J\033[H'
  fi
}

menu_flash() {
  MENU_FLASH_WARN=0
  MENU_FLASH_MSG=$*
}

menu_flash_warn() {
  MENU_FLASH_WARN=1
  MENU_FLASH_MSG=$*
}

menu_flash_step() {
  local name=$1 on=$2
  if (( on )); then
    menu_flash "${name}: ${GREEN}ativada${NC}"
  else
    menu_flash "${name}: desativada"
  fi
}

usage() {
  cat <<'EOF'
cleanup-mac.sh — limpeza de caches e arquivos temporários (macOS)

Opções:
  --dry-run       Estimativa resumida do que seria limpo (sem apagar arquivos)
  --dry-run-verbose
                  Com --dry-run, lista cada arquivo/pasta (inventário detalhado)
  --yes           Aceita etapas seguras sem perguntar (arriscadas ainda pedem)
  --yes-all       Aceita tudo sem perguntar (inclui resíduos, sudo, Docker agressivo)
  --full          Alias de --yes-all
  --caches-only   Só lixeira, caches, logs (sem resíduos, Xcode, dev tools, sudo)
  --caches-safe   Só caches conhecidos (dev/navegadores), não ~/Library/Caches inteiro
  --skip-orphans  Não analisa/remove resíduos de apps desinstalados
  --orphans-include-sensitive
                  Inclui Preferences/Containers na busca de resíduos (mais arriscado)
  --menu          Abre o menu interativo (padrão ao rodar sem flags no terminal)
  --classic       Fluxo sequencial com perguntas (sem menu)
  --help          Esta ajuda

Exemplos:
  ./cleanup-mac.sh --dry-run
  ./cleanup-mac.sh
  ./cleanup-mac.sh --yes
  ./cleanup-mac.sh --full

Instalação (opcional):
  chmod +x cleanup-mac.sh
  ln -sf "$(pwd)/cleanup-mac.sh" ~/bin/cleanup-mac   # se ~/bin estiver no PATH
EOF
}

log()  { printf '%b\n' "${BLUE}[*]${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}[✓]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[!]${NC} $*"; }
err()  { printf '%b\n' "${RED}[✗]${NC} $*" >&2; }

human_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    LC_ALL=C awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b/1073741824 }'
  elif (( bytes >= 1048576 )); then
    LC_ALL=C awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b/1048576 }'
  elif (( bytes >= 1024 )); then
    LC_ALL=C awk -v b="$bytes" 'BEGIN { printf "%.2f KB", b/1024 }'
  else
    printf "%d B" "$bytes"
  fi
}

dir_size_bytes() {
  local path=$1
  local kb
  [[ -e "$path" ]] || { echo 0; return; }
  kb=$(du -sk "$path" 2>/dev/null | LC_ALL=C awk 'NR==1 { print $1; exit }')
  [[ -z "$kb" || ! "$kb" =~ ^[0-9]+$ ]] && { echo 0; return; }
  echo $(( kb * 1024 ))
}

confirm() {
  local prompt=$1
  if (( ASSUME_YES || DRY_RUN || (MENU_MODE && MENU_CONFIRMED) )); then
    return 0
  fi
  read -r -p "$(printf '%b' "${YELLOW}${prompt} [s/N]:${NC} ")" ans
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  [[ "$ans" == "s" || "$ans" == "sim" || "$ans" == "y" || "$ans" == "yes" ]]
}

# Etapas destrutivas ou com sudo — nunca puladas com --yes
confirm_risky() {
  local prompt=$1
  if (( DRY_RUN )); then
    return 0
  fi
  if (( YES_ALL || (MENU_MODE && MENU_RISKY_OK) )); then
    return 0
  fi
  read -r -p "$(printf '%b' "${RED}${prompt} [s/N]:${NC} ")" ans
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  [[ "$ans" == "s" || "$ans" == "sim" || "$ans" == "y" || "$ans" == "yes" ]]
}

count_immediate_children() {
  local dir=$1
  find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# Imprime linha de resumo e acumula FREED_BYTES (dry-run compacto)
dry_run_report_step() {
  local label=$1
  local count=$2
  local bytes=$3
  local note=${4:-}

  (( bytes == 0 && count == 0 )) && return 0
  if [[ -n "$note" ]]; then
    ui_out "$(printf "  ${GREEN}•${NC} %-44s %5s itens  ${BLUE}~%-9s${NC}  (%s)" \
      "$label" "$count" "$(human_size "$bytes")" "$note")"
  else
    ui_out "$(printf "  ${GREEN}•${NC} %-44s %5s itens  ${BLUE}~%-9s${NC}" \
      "$label" "$count" "$(human_size "$bytes")")"
  fi
  FREED_BYTES=$((FREED_BYTES + bytes))
}

dry_run_print_banner() {
  echo ""
  ui_out "${BLUE}── O que seria feito (estimativa em disco) ──${NC}"
}

dry_run_print_total() {
  echo ""
  ok "Total estimado em disco: ~$(human_size "$FREED_BYTES")"
  if (( FREED_BYTES == 0 )); then
    log "Nada significativo encontrado nas etapas selecionadas."
  fi
  echo ""
}

dry_run_list_path_entries() {
  local label=$1
  local dir=$2
  local tmp count=0 total=0 size entry

  [[ -d "$dir" ]] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cleanup-mac-list.XXXXXX")

  while IFS= read -r entry; do
    size=$(dir_size_bytes "$entry")
    (( size == 0 )) && continue
    printf '%s\t%s\n' "$size" "$entry" >>"$tmp"
    total=$((total + size))
    count=$((count + 1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)

  if (( count == 0 )); then
    rm -f "$tmp"
    return 0
  fi

  if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
    dry_run_report_step "$label" "$count" "$total"
    rm -f "$tmp"
    return 0
  fi

  log "${label} — ${count} item(ns), ~$(human_size "$total") em ${dir}"
  while IFS=$'\t' read -r size entry; do
    printf '  - %s  %s\n' "$(human_size "$size")" "$entry"
  done < <(sort -nr "$tmp")
  rm -f "$tmp"
  FREED_BYTES=$((FREED_BYTES + total))
}

dry_run_list_glob_files() {
  local label=$1
  local root=$2
  local mindepth=${3:-1}
  local maxdepth=${4:-1}
  local tmp count=0 total=0 size path

  [[ -d "$root" ]] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cleanup-mac-list.XXXXXX")

  while IFS= read -r path; do
    size=$(dir_size_bytes "$path")
    (( size == 0 )) && continue
    printf '%s\t%s\n' "$size" "$path" >>"$tmp"
    total=$((total + size))
    count=$((count + 1))
  done < <(find "$root" -mindepth "$mindepth" -maxdepth "$maxdepth" 2>/dev/null)

  if (( count == 0 )); then
    rm -f "$tmp"
    return 0
  fi

  log "${label} — ${count} item(ns), ~$(human_size "$total")"
  while IFS=$'\t' read -r size path; do
    printf '  - %s  %s\n' "$(human_size "$size")" "$path"
  done < <(sort -nr "$tmp")
  rm -f "$tmp"
}

clear_dir_contents() {
  local label=$1
  local dir=$2
  local skip_confirm=${3:-}
  local before

  [[ -d "$dir" ]] || return 0
  before=$(dir_size_bytes "$dir")
  (( before == 0 )) && return 0

  if (( DRY_RUN )); then
    if (( DRY_RUN_VERBOSE )); then
      dry_run_list_path_entries "$label" "$dir"
    else
      dry_run_report_step "$label" "$(count_immediate_children "$dir")" "$before"
    fi
    return 0
  fi

  log "$label — $(human_size "$before") em $dir"
  if [[ "$skip_confirm" != "skip-confirm" ]] && ! confirm "Limpar $label?"; then
    warn "Pulado: $label"
    return 0
  fi

  # Mantém a pasta; remove só o conteúdo (inclui dotfiles de 1º nível)
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  ok "Limpo: $label (~$(human_size "$before"))"
  FREED_BYTES=$((FREED_BYTES + before))
}

cache_entry_skipped() {
  local base=$1
  local skip
  if (( ${#CLEANUP_CACHE_SKIP[@]} == 0 )); then
    return 1
  fi
  for skip in "${CLEANUP_CACHE_SKIP[@]}"; do
    [[ "$base" == "$skip" ]] && return 0
  done
  return 1
}

clear_dir_contents_selective() {
  local label=$1
  local dir=$2
  local entry base before=0 freed=0 size tmp count=0

  [[ -d "$dir" ]] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cleanup-mac-cache.XXXXXX")

  while IFS= read -r entry; do
    base=$(basename "$entry")
    cache_entry_skipped "$base" && continue
    size=$(dir_size_bytes "$entry")
    (( size == 0 )) && continue
    printf '%s\t%s\n' "$size" "$entry" >>"$tmp"
    before=$((before + size))
    count=$((count + 1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)

  if (( count == 0 )); then
    rm -f "$tmp"
    return 0
  fi

  if (( DRY_RUN )); then
    if (( DRY_RUN_VERBOSE )); then
      log "${label} — ${count} item(ns), ~$(human_size "$before") em ${dir}"
      while IFS=$'\t' read -r size entry; do
        printf '  - %s  %s\n' "$(human_size "$size")" "$entry"
      done < <(sort -nr "$tmp")
      FREED_BYTES=$((FREED_BYTES + before))
    else
      dry_run_report_step "$label" "$count" "$before"
    fi
    rm -f "$tmp"
    return 0
  fi

  log "$label — ~$(human_size "$before") em $dir"
  if ! confirm "Limpar $label (respeitando lista de preservação)?"; then
    warn "Pulado: $label"
    rm -f "$tmp"
    return 0
  fi

  while IFS=$'\t' read -r size entry; do
    rm -rf "$entry" 2>/dev/null || true
    freed=$((freed + size))
  done <"$tmp"
  rm -f "$tmp"

  ok "Limpo: $label (~$(human_size "$freed"))"
  FREED_BYTES=$((FREED_BYTES + freed))
}

clear_user_caches() {
  local dir="$HOME/Library/Caches"
  local name path

  if (( CACHES_SAFE )); then
    log "Modo --caches-safe: subpastas selecionadas em $dir"
    for name in "${CACHES_SAFE_ENTRIES[@]}"; do
      path="$dir/$name"
      [[ -e "$path" ]] || continue
      clear_dir_contents "Cache ($name)" "$path"
    done
    return 0
  fi

  clear_dir_contents_selective "Caches do usuário" "$dir"
  USER_CACHES_FULL=1
}

run_cmd() {
  local label=$1
  shift
  log "$label"
  if (( DRY_RUN )); then
    ok "(dry-run) Executaria: $*"
    return 0
  fi
  if "$@"; then
    ok "Feito: $label"
  else
    warn "Falhou ou nada a fazer: $label"
  fi
}

empty_trash() {
  local before=0
  local trash="$HOME/.Trash"

  if [[ -d "$trash" ]]; then
    before=$(dir_size_bytes "$trash")
  fi
  (( before == 0 )) && { log "Lixeira já vazia"; return 0; }

  if (( DRY_RUN )); then
    if (( DRY_RUN_VERBOSE )); then
      dry_run_list_path_entries "Lixeira" "$trash"
    else
      dry_run_report_step "Lixeira" "$(count_immediate_children "$trash")" "$before"
    fi
    return 0
  fi

  log "Lixeira — $(human_size "$before")"
  if ! confirm "Esvaziar a Lixeira?"; then
    warn "Pulado: Lixeira"
    return 0
  fi

  osascript -e 'tell application "Finder" to empty trash' 2>/dev/null \
    || find "$HOME/.Trash" -mindepth 1 -delete 2>/dev/null \
    || true
  ok "Lixeira esvaziada (~$(human_size "$before"))"
  FREED_BYTES=$((FREED_BYTES + before))
}

# --- Resíduos de apps desinstalados -------------------------------------------

CLEANUP_MAC_TMPDIR=""

cleanup_temp_index() {
  [[ -n "$CLEANUP_MAC_TMPDIR" && -d "$CLEANUP_MAC_TMPDIR" ]] && rm -rf "$CLEANUP_MAC_TMPDIR"
  CLEANUP_MAC_TMPDIR=""
}

build_installed_app_index() {
  local app
  local name
  local bundle_id
  local display_name
  local -a app_roots=(/Applications /System/Applications "${HOME}/Applications")

  cleanup_temp_index
  CLEANUP_MAC_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-mac.XXXXXX")
  INSTALLED_BUNDLE_IDS="${CLEANUP_MAC_TMPDIR}/bundle_ids"
  INSTALLED_APP_NAMES="${CLEANUP_MAC_TMPDIR}/app_names"
  : >"$INSTALLED_BUNDLE_IDS"
  : >"$INSTALLED_APP_NAMES"

  log "Indexando aplicativos instalados (.app)..."
  while IFS= read -r app; do
    [[ -d "$app/Contents" ]] || continue
    name=$(basename "$app" .app)
    printf '%s\n' "$name" >>"$INSTALLED_APP_NAMES"

    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    [[ -n "$bundle_id" ]] && printf '%s\n' "$bundle_id" >>"$INSTALLED_BUNDLE_IDS"

    display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist" 2>/dev/null || true)
    [[ -n "$display_name" ]] && printf '%s\n' "$display_name" >>"$INSTALLED_APP_NAMES"

    display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist" 2>/dev/null || true)
    [[ -n "$display_name" ]] && printf '%s\n' "$display_name" >>"$INSTALLED_APP_NAMES"
  done < <(find "${app_roots[@]}" -maxdepth 4 -name '*.app' 2>/dev/null)

  sort -fu "$INSTALLED_BUNDLE_IDS" -o "$INSTALLED_BUNDLE_IDS"
  sort -fu "$INSTALLED_APP_NAMES" | LC_ALL=C awk '{ print tolower($0) }' | sort -fu -o "$INSTALLED_APP_NAMES"
}

leftover_name_whitelisted() {
  local key=$1
  local lower
  lower=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    shared|clouddocs|icloud|apple|android|network|syncservices|mobilesync|callhistorydb|\
    knowledge|homekit|messages|mail|contacts|calendar|loginwindow|dock|finder|system|\
    metadata|spelling|translation|safari|suggestions|biome|assistant|corefollowup|\
    studentd|familycircle|passd|identityservices|cloudkit|weather|stocks|news|\
    photos|photostream|screenrecording|accessibility|universalaccess)
      return 0
      ;;
  esac

  [[ "$key" == com.apple.* ]] && return 0
  [[ "$key" == group.com.apple.* ]] && return 0
  return 1
}

bundle_id_matches_installed() {
  local candidate=$1
  local installed

  [[ -z "$candidate" ]] && return 1
  leftover_name_whitelisted "$candidate" && return 0

  while IFS= read -r installed; do
    [[ -z "$installed" ]] && continue
    [[ "$candidate" == "$installed" ]] && return 0
    [[ "$candidate" == "$installed."* ]] && return 0
    [[ "$installed" == "$candidate."* ]] && return 0
  done <"$INSTALLED_BUNDLE_IDS"
  return 1
}

app_name_matches_installed() {
  local candidate=$1
  local lower
  lower=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')

  [[ -z "$lower" ]] && return 1
  leftover_name_whitelisted "$candidate" && return 0
  grep -Fqx "$lower" "$INSTALLED_APP_NAMES" 2>/dev/null
}

leftover_entry_matches_installed() {
  local entry_name=$1
  local stem=$entry_name

  stem=${stem%.plist}
  stem=${stem%.lockfile}
  stem=${stem%.plugin}
  stem=${stem%.prefPane}
  stem=${stem%.app}
  if [[ "$stem" == *"_byhost" ]]; then
    stem=${stem%%.*}
  fi

  if [[ "$stem" == *.* ]]; then
    bundle_id_matches_installed "$stem" && return 0
  fi
  app_name_matches_installed "$stem" && return 0
  app_name_matches_installed "$entry_name" && return 0
  return 1
}

append_orphan_candidate() {
  local path=$1
  local size
  local dest=${ORPHAN_LIST_PATH:-}
  [[ -n "$dest" ]] || return 0
  [[ -e "$path" ]] || return 0
  size=$(dir_size_bytes "$path")
  (( size == 0 )) && return 0
  printf '%s\t%s\n' "$size" "$path" >>"$dest"
}

collect_broken_app_bundles() {
  local -a app_roots=(/Applications "${HOME}/Applications")
  local app

  ORPHAN_LIST_PATH="$ORPHAN_CANDIDATES"
  while IFS= read -r app; do
    [[ -f "$app/Contents/Info.plist" ]] && continue
    append_orphan_candidate "$app"
  done < <(find "${app_roots[@]}" -maxdepth 4 -name '*.app' 2>/dev/null)
}

collect_library_leftovers_in_roots() {
  local lib_dir entry base

  for lib_dir in "$@"; do
    [[ -d "$lib_dir" ]] || continue
    while IFS= read -r entry; do
      base=$(basename "$entry")
      [[ "$base" == .DS_Store ]] && continue
      leftover_entry_matches_installed "$base" && continue
      append_orphan_candidate "$entry"
    done < <(find "$lib_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type f -o -type l \) 2>/dev/null)
  done
}

collect_library_leftovers() {
  local -a standard_roots=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Logs"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/WebKit"
    "$HOME/Library/PreferencePanes"
    "$HOME/Library/Internet Plug-Ins"
    "$HOME/Library/Services"
    "$HOME/Library/Application Support/CrashReporter"
  )
  local -a sensitive_roots=(
    "$HOME/Library/Containers"
    "$HOME/Library/Group Containers"
    "$HOME/Library/HTTPStorages"
    "$HOME/Library/Preferences"
  )

  ORPHAN_LIST_PATH="$ORPHAN_CANDIDATES"
  collect_library_leftovers_in_roots "${standard_roots[@]}"

  if (( ORPHANS_SENSITIVE )); then
    ORPHAN_LIST_PATH="$ORPHAN_CANDIDATES_SENSITIVE"
    collect_library_leftovers_in_roots "${sensitive_roots[@]}"
  fi
}

orphan_list_stats() {
  local file=$1
  local total_bytes=0
  local count=0
  local size path

  [[ -f "$file" ]] || { echo "0 0"; return; }
  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    total_bytes=$((total_bytes + size))
    count=$((count + 1))
  done <"$file"
  echo "$count $total_bytes"
}

print_orphan_preview() {
  local title=$1
  local file=$2
  local preview_limit=$3
  local stats count total_bytes

  stats=$(orphan_list_stats "$file")
  count=${stats%% *}
  total_bytes=${stats#* }
  (( count == 0 )) && return 0

  if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
    dry_run_report_step "$title" "$count" "$total_bytes"
    return 0
  fi

  log "${title} — ${count} item(ns), ~$(human_size "$total_bytes")"
  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    printf '  - %s  %s\n' "$(human_size "$size")" "$path"
  done < <(sort -nr "$file" | head -n "$preview_limit")
  if (( count > preview_limit )); then
    printf '  ... e mais %s item(ns)\n' "$((count - preview_limit))"
  fi
}

remove_orphan_file() {
  local file=$1
  local size path

  [[ -f "$file" ]] || return 0
  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    rm -rf "$path" 2>/dev/null || true
    ok "Resíduo removido: $path (~$(human_size "$size"))"
    FREED_BYTES=$((FREED_BYTES + size))
  done < <(sort -nr "$file")
}

purge_uninstalled_app_leftovers() {
  local ORPHAN_CANDIDATES=""
  local ORPHAN_CANDIDATES_SENSITIVE=""
  local preview_limit=40
  local stats_std stats_sens
  local count_std=0 count_sens=0 total_std=0 total_sens=0

  if (( DRY_RUN && DRY_RUN_VERBOSE )); then
    preview_limit=999999
  fi

  ORPHAN_CANDIDATES="${CLEANUP_MAC_TMPDIR:-${TMPDIR:-/tmp}}/orphans.$$"
  ORPHAN_CANDIDATES_SENSITIVE="${CLEANUP_MAC_TMPDIR:-${TMPDIR:-/tmp}}/orphans-sensitive.$$"
  : >"$ORPHAN_CANDIDATES"
  : >"$ORPHAN_CANDIDATES_SENSITIVE"

  build_installed_app_index
  collect_broken_app_bundles
  collect_library_leftovers

  stats_std=$(orphan_list_stats "$ORPHAN_CANDIDATES")
  count_std=${stats_std%% *}
  total_std=${stats_std#* }
  stats_sens=$(orphan_list_stats "$ORPHAN_CANDIDATES_SENSITIVE")
  count_sens=${stats_sens%% *}
  total_sens=${stats_sens#* }

  if (( count_std + count_sens == 0 )); then
    ok "Nenhum resíduo óbvio de app desinstalado encontrado"
    cleanup_temp_index
    rm -f "$ORPHAN_CANDIDATES" "$ORPHAN_CANDIDATES_SENSITIVE"
    return 0
  fi

  if (( ! DRY_RUN )); then
    warn "Revise a lista: pastas genéricas (ex.: Google, Adobe) podem ser de apps ainda em uso."
  fi
  if (( ! ORPHANS_SENSITIVE && count_sens == 0 )); then
    log "Preferences/Containers não incluídos (use --orphans-include-sensitive para analisar)."
  fi

  print_orphan_preview "Resíduos (Application Support, Logs, etc.)" "$ORPHAN_CANDIDATES" "$preview_limit"
  if (( ORPHANS_SENSITIVE && count_sens > 0 )); then
    warn "Itens sensíveis (Preferences/Containers): podem apagar configurações ou dados sandbox."
    print_orphan_preview "Resíduos sensíveis" "$ORPHAN_CANDIDATES_SENSITIVE" "$preview_limit"
  fi

  if (( DRY_RUN )); then
    if (( DRY_RUN_VERBOSE )); then
      FREED_BYTES=$((FREED_BYTES + total_std + total_sens))
    fi
    cleanup_temp_index
    rm -f "$ORPHAN_CANDIDATES" "$ORPHAN_CANDIDATES_SENSITIVE"
    return 0
  fi

  if (( count_std > 0 )); then
    if confirm_risky "Remover resíduos listados (Application Support, Logs, etc.)?"; then
      remove_orphan_file "$ORPHAN_CANDIDATES"
    else
      warn "Pulado: resíduos padrão"
    fi
  fi

  if (( ORPHANS_SENSITIVE && count_sens > 0 )); then
    if confirm_risky "Remover resíduos SENSÍVEIS (Preferences/Containers/HTTPStorages)?"; then
      remove_orphan_file "$ORPHAN_CANDIDATES_SENSITIVE"
    else
      warn "Pulado: resíduos sensíveis"
    fi
  fi

  cleanup_temp_index
  rm -f "$ORPHAN_CANDIDATES" "$ORPHAN_CANDIDATES_SENSITIVE"
}

purge_old_crash_reports() {
  local days=$1
  local crash_dir="$HOME/Library/Logs/DiagnosticReports"
  local tmp2 count2=0 total2=0 size2 path2

  [[ -d "$crash_dir" ]] || return 0
  tmp2=$(mktemp "${TMPDIR:-/tmp}/cleanup-mac-crash.XXXXXX")
  while IFS= read -r path2; do
    size2=$(dir_size_bytes "$path2")
    (( size2 == 0 )) && continue
    printf '%s\t%s\n' "$size2" "$path2" >>"$tmp2"
    total2=$((total2 + size2))
    count2=$((count2 + 1))
  done < <(find "$crash_dir" -type f \( -name '*.ips' -o -name '*.crash' \) -mtime +"$days" 2>/dev/null)

  if (( count2 == 0 )); then
    rm -f "$tmp2"
    return 0
  fi

  if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
    dry_run_report_step "Relatórios de crash antigos" "$count2" "$total2"
    rm -f "$tmp2"
    return 0
  fi

  log "Relatórios de crash (> ${days} dias) — ${count2} arquivo(s), ~$(human_size "$total2")"
  while IFS=$'\t' read -r size2 path2; do
    printf '  - %s  %s\n' "$(human_size "$size2")" "$path2"
  done < <(sort -nr "$tmp2")

  if (( DRY_RUN )); then
    FREED_BYTES=$((FREED_BYTES + total2))
    rm -f "$tmp2"
    return 0
  fi

  rm -f "$tmp2"
  if confirm "Remover estes relatórios de crash (.ips/.crash)?"; then
    find "$crash_dir" -type f \( -name '*.ips' -o -name '*.crash' \) -mtime +"$days" -delete 2>/dev/null || true
    ok "Relatórios de crash antigos removidos"
  else
    warn "Pulado: relatórios de crash"
  fi
}

purge_old_logs() {
  local log_dir="$HOME/Library/Logs"
  local days=30
  local before=0

  [[ -d "$log_dir" ]] || return 0
  before=$(dir_size_bytes "$log_dir")

  if (( DRY_RUN )); then
    local tmp count=0 total=0 size path
    tmp=$(mktemp "${TMPDIR:-/tmp}/cleanup-mac-logs.XXXXXX")
    while IFS= read -r path; do
      size=$(dir_size_bytes "$path")
      (( size == 0 )) && continue
      printf '%s\t%s\n' "$size" "$path" >>"$tmp"
      total=$((total + size))
      count=$((count + 1))
    done < <(find "$log_dir" -type f -mtime +"$days" 2>/dev/null)
    if (( count > 0 )); then
      if (( DRY_RUN_VERBOSE )); then
        log "Logs (> ${days} dias) — ${count} arquivo(s), ~$(human_size "$total")"
        while IFS=$'\t' read -r size path; do
          printf '  - %s  %s\n' "$(human_size "$size")" "$path"
        done < <(sort -nr "$tmp")
        FREED_BYTES=$((FREED_BYTES + total))
      else
        dry_run_report_step "Logs de usuário (> ${days} dias)" "$count" "$total"
      fi
    else
      log "Logs (> ${days} dias): nenhum arquivo elegível"
    fi
    rm -f "$tmp"
    purge_old_crash_reports "$days"
    return 0
  fi

  log "Logs do usuário (> ${days} dias) — pasta total ~$(human_size "$before")"
  if confirm "Remover arquivos de log com mais de ${days} dias?"; then
    find "$log_dir" -type f -mtime +"$days" -delete 2>/dev/null || true
    ok "Logs antigos removidos"
  else
    warn "Pulado: logs antigos"
  fi

  purge_old_crash_reports "$days"
}

dev_tool_cleanup() {
  local compact=0 dev_est=0 dev_parts=0

  (( DRY_RUN && ! DRY_RUN_VERBOSE )) && compact=1

  if command -v brew >/dev/null 2>&1; then
    local brew_cache
    brew_cache=$(dir_size_bytes "$(brew --cache 2>/dev/null || echo "")")
    if (( ! compact )); then
      log "Homebrew — cache ~$(human_size "$brew_cache")"
    fi
    if confirm "Rodar brew cleanup (remove caches e versões antigas)?"; then
      if (( compact )); then
        dev_est=$((dev_est + brew_cache))
        dev_parts=$((dev_parts + 1))
      elif (( DRY_RUN )); then
        log "Homebrew — simulação (brew cleanup -n):"
        brew cleanup -n 2>/dev/null | sed 's/^/  /' || ok "(dry-run) brew cleanup -s && brew autoremove"
      else
        log "Homebrew — prévia (brew cleanup -n):"
        brew cleanup -n 2>/dev/null | sed 's/^/  /' || true
        brew cleanup -s 2>/dev/null || true
        brew autoremove 2>/dev/null || true
        ok "Homebrew cleanup concluído"
      fi
    fi
  fi

  if command -v npm >/dev/null 2>&1; then
    if confirm "Limpar cache do npm?"; then
      if (( compact )); then
        dev_est=$((dev_est + $(dir_size_bytes "$(npm config get cache 2>/dev/null || echo "$HOME/.npm")")))
        dev_parts=$((dev_parts + 1))
      elif (( DRY_RUN )); then
        log "npm cache — $(npm config get cache 2>/dev/null || echo '?')"
        dry_run_list_path_entries "npm cache" "$(npm config get cache 2>/dev/null || echo "$HOME/.npm")"
      else
        run_cmd "npm cache" npm cache clean --force
      fi
    fi
  fi

  if command -v yarn >/dev/null 2>&1; then
    if confirm "Limpar cache do Yarn?"; then
      if (( compact )); then
        dev_est=$((dev_est + $(dir_size_bytes "$(yarn cache dir 2>/dev/null || echo "$HOME/Library/Caches/Yarn")")))
        dev_parts=$((dev_parts + 1))
      elif (( DRY_RUN )); then
        log "Yarn cache — $(yarn cache dir 2>/dev/null || echo '?')"
        dry_run_list_path_entries "Yarn cache" "$(yarn cache dir 2>/dev/null || echo "$HOME/Library/Caches/Yarn")"
      else
        run_cmd "Yarn cache" yarn cache clean
      fi
    fi
  fi

  if command -v pip3 >/dev/null 2>&1; then
    if confirm "Limpar cache do pip?"; then
      if (( compact )); then
        dev_est=$((dev_est + $(dir_size_bytes "$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")")))
        dev_parts=$((dev_parts + 1))
      elif (( DRY_RUN )); then
        local pip_cache
        pip_cache=$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")
        log "pip cache — $pip_cache"
        dry_run_list_path_entries "pip cache" "$pip_cache"
      else
        run_cmd "pip cache" pip3 cache purge
      fi
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    if (( ! compact )); then
      warn "Docker: remove imagens/containers/volumes NÃO usados (pode ser grande)."
    fi
    if confirm "Rodar docker system prune -f (sem volumes)?"; then
      if (( compact )); then
        dry_run_report_step "Docker (prune -f)" "—" "0" "use: docker system df"
      elif (( DRY_RUN )); then
        log "Docker — espaço recuperável (docker system df):"
        docker system df 2>/dev/null | sed 's/^/  /' || true
        ok "(dry-run) Executaria: docker system prune -f"
      else
        run_cmd "Docker prune" docker system prune -f
      fi
    fi
    if confirm_risky "Rodar docker system prune -af (TODAS imagens não usadas)?"; then
      if (( compact && DRY_RUN )); then
        dry_run_report_step "Docker (prune -af)" "—" "0" "agressivo — ver docker system df"
      else
        run_cmd "Docker prune agressivo" docker system prune -af
      fi
    fi
  fi

  if (( compact && dev_parts > 0 )); then
    dry_run_report_step "Ferramentas de dev (cache estimado)" "$dev_parts" "$dev_est" "parcial"
  fi
}

xcode_cleanup() {
  local derived="$HOME/Library/Developer/Xcode/DerivedData"
  local arch="$HOME/Library/Developer/Xcode/Archives"
  local ios_dev="$HOME/Library/Developer/CoreSimulator/Caches"

  if [[ -d "$derived" ]]; then
    clear_dir_contents "Xcode DerivedData" "$derived"
  fi

  if [[ -d "$arch" ]]; then
    warn "Archives do Xcode contêm builds antigos para App Store — só apague se souber o que está fazendo."
    if confirm_risky "Apagar Xcode Archives em $arch?"; then
      clear_dir_contents "Xcode Archives" "$arch" skip-confirm
    fi
  fi

  if [[ -d "$ios_dev" ]]; then
    clear_dir_contents "Cache do Simulador iOS" "$ios_dev"
  fi

  if xcrun simctl help >/dev/null 2>&1; then
    if confirm "Remover simuladores iOS indisponíveis (simctl delete unavailable)?"; then
      if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
        dry_run_report_step "Simuladores iOS indisponíveis" "—" "0" "simctl delete unavailable"
      elif (( DRY_RUN )); then
        ok "(dry-run) xcrun simctl delete unavailable"
      else
        run_cmd "Simuladores indisponíveis" xcrun simctl delete unavailable
      fi
    fi
  fi

  purge_old_ios_device_support
}

purge_old_ios_device_support() {
  local base="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  local days=180
  local tmp count=0 total=0 size path

  [[ -d "$base" ]] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cleanup-mac-devsupport.XXXXXX")

  while IFS= read -r path; do
    size=$(dir_size_bytes "$path")
    (( size == 0 )) && continue
    printf '%s\t%s\n' "$size" "$path" >>"$tmp"
    total=$((total + size))
    count=$((count + 1))
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null)

  if (( count == 0 )); then
    rm -f "$tmp"
    return 0
  fi

  if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
    dry_run_report_step "Xcode iOS DeviceSupport (> ${days}d)" "$count" "$total"
    rm -f "$tmp"
    return 0
  fi

  log "Xcode iOS DeviceSupport (> ${days} dias) — ${count} pasta(s), ~$(human_size "$total")"
  while IFS=$'\t' read -r size path; do
    printf '  - %s  %s\n' "$(human_size "$size")" "$path"
  done < <(sort -nr "$tmp")

  if (( DRY_RUN )); then
    FREED_BYTES=$((FREED_BYTES + total))
    rm -f "$tmp"
    return 0
  fi

  if confirm_risky "Remover DeviceSupport antigo (só necessário para depurar iOS na mesma versão)?"; then
    while IFS=$'\t' read -r size path; do
      rm -rf "$path" 2>/dev/null || true
      FREED_BYTES=$((FREED_BYTES + size))
    done < <(sort -nr "$tmp")
    ok "DeviceSupport antigo removido (~$(human_size "$total"))"
  else
    warn "Pulado: iOS DeviceSupport"
  fi
  rm -f "$tmp"
}

optional_memory_purge() {
  warn "Memória (RAM): 'purge' descarta cache inativo de arquivos na RAM — não libera espaço em disco."
  warn "Pode causar lentidão breve enquanto apps relêem arquivos; o macOS já gerencia memória sozinho."
  if ! confirm_risky "Executar sudo purge (cache de memória)?"; then
    return 0
  fi
  if (( DRY_RUN )); then
    dry_run_report_step "purge — cache de RAM (sudo)" "—" "0" "não libera disco"
    return 0
  fi
  if sudo purge 2>/dev/null; then
    ok "purge concluído (RAM/cache de leitura)"
  else
    warn "purge falhou ou comando indisponível nesta versão do macOS"
  fi
}

optional_system() {
  warn "Etapa opcional com sudo: snapshots locais do Time Machine e cache de fontes."
  if ! confirm_risky "Continuar com limpeza que pode pedir senha de administrador?"; then
    return 0
  fi
  optional_system_body
}

optional_system_body() {

  if command -v tmutil >/dev/null 2>&1; then
    local snaps
    snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
    if (( snaps > 0 )); then
      log "Encontrados $snaps snapshot(s) local(is) do Time Machine"
      if confirm_risky "Remover snapshots locais (libera espaço no disco de boot)?"; then
        if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
          dry_run_report_step "Snapshots locais Time Machine" "$snaps" "0" "tamanho não estimado aqui"
        elif (( DRY_RUN )); then
          log "Snapshots locais do Time Machine (seriam removidos):"
          tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/  - /' || true
        else
          while read -r snap; do
            [[ -z "$snap" ]] && continue
            sudo tmutil deletelocalsnapshots "$snap" 2>/dev/null || true
          done < <(tmutil listlocalsnapshots / 2>/dev/null | sed 's/com.apple.TimeMachine.//')
          ok "Snapshots locais processados"
        fi
      fi
    fi
  fi

  if confirm_risky "Limpar cache de fontes do sistema (sudo)?"; then
    if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
      dry_run_report_step "Cache de fontes do sistema (sudo)" "—" "0" "geralmente pequeno"
    elif (( DRY_RUN )); then
      ok "(dry-run) atsutil databases -remove"
    else
      sudo atsutil databases -remove 2>/dev/null || true
      ok "Cache de fontes limpo"
    fi
  fi
}

menu_mark() {
  if (( $1 )); then
    printf '%b' "${GREEN}[x]${NC}"
  else
    printf '[ ]'
  fi
}

menu_has_risky_selection() {
  (( STEP_ORPHANS || STEP_ORPHANS_SENSITIVE || STEP_XCODE || STEP_DEVTOOLS || STEP_SYSTEM_SUDO || STEP_MEMORY_PURGE ))
}

menu_draw() {
  local os_ver free_disk bar title_line w=$UI_PANEL_INNER
  os_ver=$(sw_vers -productVersion 2>/dev/null || echo "?")
  free_disk=$(df -k / | LC_ALL=C awk 'NR==2 { print $4 * 1024; exit }')
  bar=$(repeat_char '─' "$w")

  ui_clear_screen
  ui_out "${GREEN}╭${bar}╮${NC}"
  title_line=$(ui_pad_in_box "Limpeza macOS — menu interativo" "$w")
  ui_out "${GREEN}│${NC}${title_line}${GREEN}│${NC}"
  ui_out "${GREEN}╰${bar}╯${NC}"
  if [[ -n "$MENU_FLASH_MSG" ]]; then
    echo ""
    if (( MENU_FLASH_WARN )); then
      ui_out "  ${YELLOW}!${NC} ${MENU_FLASH_MSG}"
    else
      ui_out "  ${GREEN}→${NC} ${MENU_FLASH_MSG}"
    fi
    MENU_FLASH_MSG=""
    MENU_FLASH_WARN=0
  fi
  echo ""
  ui_out "$(printf '  macOS %-11s  Espaço livre: %b%s%b' "$os_ver" "$BLUE" "$(human_size "$free_disk")" "$NC")"
  if (( DRY_RUN )); then
    ui_out "  ${YELLOW}Dry-run — só estimativa, nada será apagado${NC}"
  fi
  if (( ASSUME_YES && ! DRY_RUN )); then
    ui_out "  ${YELLOW}Etapas seguras sem perguntas repetidas${NC}"
  fi
  echo ""
  ui_out "  ${BLUE}Número liga/desliga · s = simular · g = executar · q = sair${NC}"
  echo ""
  ui_out "  $(menu_mark "$STEP_TRASH")  ${BLUE}1${NC}  Esvaziar Lixeira"
  ui_out "  $(menu_mark "$STEP_ORPHANS")  ${BLUE}2${NC}  Resíduos de apps ${YELLOW}(arriscado)${NC}"
  ui_out "  $(menu_mark "$STEP_ORPHANS_SENSITIVE")  ${BLUE}3${NC}  + Preferences/Containers ${RED}(exige 2)${NC}"
  ui_out "  $(menu_mark "$STEP_CACHES_FULL")  ${BLUE}4${NC}  Caches ~/Library/Caches"
  ui_out "  $(menu_mark "$STEP_CACHES_SAFE")  ${BLUE}5${NC}  Caches seguros (substitui 4)"
  ui_out "  $(menu_mark "$STEP_LOGS")  ${BLUE}6${NC}  Logs e crash reports antigos"
  ui_out "  $(menu_mark "$STEP_XCODE")  ${BLUE}7${NC}  Xcode / Simulador ${YELLOW}(parcial)${NC}"
  ui_out "  $(menu_mark "$STEP_DEVTOOLS")  ${BLUE}8${NC}  Homebrew, npm, Docker…"
  ui_out "  $(menu_mark "$STEP_SYSTEM_SUDO")  ${BLUE}9${NC}  Time Machine + fontes ${RED}(sudo)${NC}"
  ui_out "  $(menu_mark "$STEP_MEMORY_PURGE")  ${BLUE}0${NC}  purge RAM ${RED}(sudo)${NC}"
  echo ""
  ui_out "  ${BLUE}p${NC}  Perfil rápido    ${BLUE}a${NC}  Perfil completo    ${BLUE}d${NC}  dry-run    ${BLUE}y${NC}  auto-aceitar    ${BLUE}s${NC}  simular"
  echo ""
}

menu_toggle() {
  local key=$1
  case "$key" in
    1) STEP_TRASH=$((1 - STEP_TRASH)); menu_flash_step "Lixeira" "$STEP_TRASH" ;;
    2) STEP_ORPHANS=$((1 - STEP_ORPHANS))
       if (( ! STEP_ORPHANS )); then
         STEP_ORPHANS_SENSITIVE=0
       fi
       menu_flash_step "Resíduos de apps" "$STEP_ORPHANS"
       ;;
    3)
       if (( ! STEP_ORPHANS )); then
         menu_flash_warn "Ative a opção 2 antes dos resíduos sensíveis."
         return 1
       fi
       STEP_ORPHANS_SENSITIVE=$((1 - STEP_ORPHANS_SENSITIVE))
       menu_flash_step "Resíduos sensíveis" "$STEP_ORPHANS_SENSITIVE"
       ;;
    4)
       STEP_CACHES_FULL=$((1 - STEP_CACHES_FULL))
       if (( STEP_CACHES_FULL )); then
         STEP_CACHES_SAFE=0
       fi
       menu_flash_step "Caches completos" "$STEP_CACHES_FULL"
       ;;
    5)
       STEP_CACHES_SAFE=$((1 - STEP_CACHES_SAFE))
       if (( STEP_CACHES_SAFE )); then
         STEP_CACHES_FULL=0
       fi
       menu_flash_step "Caches seguros" "$STEP_CACHES_SAFE"
       ;;
    6) STEP_LOGS=$((1 - STEP_LOGS)); menu_flash_step "Logs antigos" "$STEP_LOGS" ;;
    7) STEP_XCODE=$((1 - STEP_XCODE)); menu_flash_step "Xcode / Simulador" "$STEP_XCODE" ;;
    8) STEP_DEVTOOLS=$((1 - STEP_DEVTOOLS)); menu_flash_step "Ferramentas de dev" "$STEP_DEVTOOLS" ;;
    9) STEP_SYSTEM_SUDO=$((1 - STEP_SYSTEM_SUDO)); menu_flash_step "Time Machine + fontes" "$STEP_SYSTEM_SUDO" ;;
    0) STEP_MEMORY_PURGE=$((1 - STEP_MEMORY_PURGE)); menu_flash_step "purge RAM" "$STEP_MEMORY_PURGE" ;;
    p|P)
       STEP_TRASH=1
       STEP_ORPHANS=0
       STEP_ORPHANS_SENSITIVE=0
       STEP_CACHES_FULL=1
       STEP_CACHES_SAFE=0
       STEP_LOGS=1
       STEP_XCODE=0
       STEP_DEVTOOLS=0
       STEP_SYSTEM_SUDO=0
       STEP_MEMORY_PURGE=0
       menu_flash "Perfil ${GREEN}rápido${NC} aplicado (1, 4, 6)."
       ;;
    a|A)
       STEP_TRASH=1
       STEP_ORPHANS=1
       STEP_ORPHANS_SENSITIVE=0
       STEP_CACHES_FULL=1
       STEP_CACHES_SAFE=0
       STEP_LOGS=1
       STEP_XCODE=1
       STEP_DEVTOOLS=1
       STEP_SYSTEM_SUDO=1
       STEP_MEMORY_PURGE=0
       menu_flash "Perfil ${GREEN}completo${NC} aplicado (sem purge RAM)."
       ;;
    d|D)
       DRY_RUN=$((1 - DRY_RUN))
       if (( DRY_RUN )); then
         menu_flash "Dry-run ${GREEN}ativado${NC} — só estimativa ao executar (g)."
       else
         menu_flash "Dry-run desativado — execução real ao confirmar (g)."
       fi
       ;;
    y|Y)
       ASSUME_YES=$((1 - ASSUME_YES))
       if (( ASSUME_YES )); then
         menu_flash "Auto-aceitar etapas ${GREEN}seguras${NC}: sim."
       else
         menu_flash "Auto-aceitar etapas seguras: desligado."
       fi
       ;;
    *) return 1 ;;
  esac
  return 0
}

menu_validate_selection() {
  local any=0

  if (( STEP_CACHES_FULL && STEP_CACHES_SAFE )); then
    menu_flash_warn "Conflito: opções 4 e 5 não podem ficar ativas juntas."
    return 1
  fi
  if (( STEP_ORPHANS_SENSITIVE && ! STEP_ORPHANS )); then
    menu_flash_warn "Opção 3 exige a opção 2 (resíduos de apps)."
    return 1
  fi

  for v in STEP_TRASH STEP_ORPHANS STEP_CACHES_FULL STEP_CACHES_SAFE STEP_LOGS STEP_XCODE STEP_DEVTOOLS STEP_SYSTEM_SUDO STEP_MEMORY_PURGE; do
    if (( ${!v} )); then
      any=1
      break
    fi
  done
  if (( ! any )); then
    menu_flash_warn "Nenhuma etapa selecionada — use p (rápido) ou marque 1–9."
    return 1
  fi

  if (( STEP_ORPHANS_SENSITIVE )); then
    ORPHANS_SENSITIVE=1
  else
    ORPHANS_SENSITIVE=0
  fi

  return 0
}

menu_summary_line() {
  local on=$1
  local label=$2
  if (( on )); then
    ui_out "  ${GREEN}✓${NC} $label"
  fi
}

estimate_selective_caches_bytes() {
  local dir="$HOME/Library/Caches"
  local entry base total=0 count=0 size

  [[ -d "$dir" ]] || { echo "0 0"; return; }
  while IFS= read -r entry; do
    base=$(basename "$entry")
    cache_entry_skipped "$base" && continue
    size=$(dir_size_bytes "$entry")
    (( size == 0 )) && continue
    total=$((total + size))
    count=$((count + 1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
  echo "$count $total"
}

estimate_safe_caches_bytes() {
  local dir="$HOME/Library/Caches"
  local name path total=0 count=0 size

  for name in "${CACHES_SAFE_ENTRIES[@]}"; do
    path="$dir/$name"
    [[ -e "$path" ]] || continue
    size=$(dir_size_bytes "$path")
    (( size == 0 )) && continue
    total=$((total + size))
    count=$((count + 1))
  done
  echo "$count $total"
}

estimate_logs_bytes() {
  local log_dir="$HOME/Library/Logs"
  local days=30
  local crash_dir="$HOME/Library/Logs/DiagnosticReports"
  local total=0 count=0 size path

  [[ -d "$log_dir" ]] || { echo "0 0"; return; }
  while IFS= read -r path; do
    size=$(dir_size_bytes "$path")
    (( size == 0 )) && continue
    total=$((total + size))
    count=$((count + 1))
  done < <(find "$log_dir" -type f -mtime +"$days" 2>/dev/null)

  if [[ -d "$crash_dir" ]]; then
    while IFS= read -r path; do
      size=$(dir_size_bytes "$path")
      (( size == 0 )) && continue
      total=$((total + size))
      count=$((count + 1))
    done < <(find "$crash_dir" -type f \( -name '*.ips' -o -name '*.crash' \) -mtime +"$days" 2>/dev/null)
  fi
  echo "$count $total"
}

# Saída: count_std bytes_std count_sens bytes_sens (4 campos)
estimate_orphans_split() {
  local ORPHAN_CANDIDATES ORPHAN_CANDIDATES_SENSITIVE
  local stats_std stats_sens
  local saved_sensitive=$ORPHANS_SENSITIVE
  local c_std b_std c_sens b_sens

  ORPHAN_CANDIDATES="${CLEANUP_MAC_TMPDIR:-${TMPDIR:-/tmp}}/menu-orphans.$$"
  ORPHAN_CANDIDATES_SENSITIVE="${CLEANUP_MAC_TMPDIR:-${TMPDIR:-/tmp}}/menu-orphans-sens.$$"
  : >"$ORPHAN_CANDIDATES"
  : >"$ORPHAN_CANDIDATES_SENSITIVE"

  ORPHANS_SENSITIVE=1
  build_installed_app_index
  collect_broken_app_bundles
  collect_library_leftovers
  ORPHANS_SENSITIVE=$saved_sensitive

  stats_std=$(orphan_list_stats "$ORPHAN_CANDIDATES")
  c_std=${stats_std%% *}
  b_std=${stats_std#* }
  stats_sens=$(orphan_list_stats "$ORPHAN_CANDIDATES_SENSITIVE")
  c_sens=${stats_sens%% *}
  b_sens=${stats_sens#* }

  rm -f "$ORPHAN_CANDIDATES" "$ORPHAN_CANDIDATES_SENSITIVE"
  cleanup_temp_index
  echo "$c_std $b_std $c_sens $b_sens"
}

estimate_orphans_bytes() {
  local split c_std b_std c_sens b_sens
  split=$(estimate_orphans_split)
  c_std=${split%% *}
  split=${split#* }
  b_std=${split%% *}
  split=${split#* }
  c_sens=${split%% *}
  b_sens=${split#* }
  echo "$((c_std + c_sens)) $((b_std + b_sens))"
}

estimate_xcode_bytes() {
  local total=0 count=0 size c b
  local derived="$HOME/Library/Developer/Xcode/DerivedData"
  local ios_dev="$HOME/Library/Developer/CoreSimulator/Caches"
  local base="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  local days=180 path

  if [[ -d "$derived" ]]; then
    size=$(dir_size_bytes "$derived")
    if (( size > 0 )); then
      total=$((total + size))
      count=$((count + 1))
    fi
  fi
  if [[ -d "$ios_dev" ]]; then
    size=$(dir_size_bytes "$ios_dev")
    if (( size > 0 )); then
      total=$((total + size))
      count=$((count + 1))
    fi
  fi
  if [[ -d "$base" ]]; then
    while IFS= read -r path; do
      size=$(dir_size_bytes "$path")
      (( size == 0 )) && continue
      total=$((total + size))
      count=$((count + 1))
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null)
  fi
  echo "$count $total"
}

estimate_devtools_bytes() {
  local total=0 parts=0

  if command -v brew >/dev/null 2>&1; then
    total=$((total + $(dir_size_bytes "$(brew --cache 2>/dev/null || echo "")")))
    parts=$((parts + 1))
  fi
  if command -v npm >/dev/null 2>&1; then
    total=$((total + $(dir_size_bytes "$(npm config get cache 2>/dev/null || echo "$HOME/.npm")")))
    parts=$((parts + 1))
  fi
  if command -v yarn >/dev/null 2>&1; then
    total=$((total + $(dir_size_bytes "$(yarn cache dir 2>/dev/null || echo "$HOME/Library/Caches/Yarn")")))
    parts=$((parts + 1))
  fi
  if command -v pip3 >/dev/null 2>&1; then
    total=$((total + $(dir_size_bytes "$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")")))
    parts=$((parts + 1))
  fi
  echo "$parts $total"
}

menu_sim_row() {
  local num=$1
  local selected=$2
  local label=$3
  local count=$4
  local bytes=$5
  local note=${6:-}
  local mark extra

  if (( selected )); then
    mark="${GREEN}[x]${NC}"
  else
    mark="[ ]"
  fi
  extra=""
  [[ -n "$note" ]] && extra=" (${note})"
  ui_out "$(printf "  %b  ${BLUE}%s${NC}  %-34s %5s itens  ${BLUE}~%-9s${NC}%b" \
    "$mark" "$num" "$label" "$count" "$(human_size "$bytes")" "$extra")"
}

menu_sum_selected_total_bytes() {
  local total=0
  local stats c b parts split
  local c_std b_std c_sens b_sens

  if (( STEP_TRASH )); then
    total=$((total + $(dir_size_bytes "$HOME/.Trash")))
  fi
  if (( STEP_ORPHANS || STEP_ORPHANS_SENSITIVE )); then
    split=$(estimate_orphans_split)
    c_std=${split%% *}
    split=${split#* }
    b_std=${split%% *}
    split=${split#* }
    c_sens=${split%% *}
    b_sens=${split#* }
    if (( STEP_ORPHANS )); then
      total=$((total + b_std))
    fi
    if (( STEP_ORPHANS && STEP_ORPHANS_SENSITIVE )); then
      total=$((total + b_sens))
    fi
  fi
  if (( STEP_CACHES_FULL )); then
    stats=$(estimate_selective_caches_bytes)
    total=$((total + ${stats#* }))
  elif (( STEP_CACHES_SAFE )); then
    stats=$(estimate_safe_caches_bytes)
    total=$((total + ${stats#* }))
  fi
  if (( STEP_LOGS )); then
    stats=$(estimate_logs_bytes)
    total=$((total + ${stats#* }))
  fi
  if (( STEP_XCODE )); then
    stats=$(estimate_xcode_bytes)
    total=$((total + ${stats#* }))
  fi
  if (( STEP_DEVTOOLS )); then
    stats=$(estimate_devtools_bytes)
    total=$((total + ${stats#* }))
  fi
  echo "$total"
}

menu_run_simulation() {
  local stats c b parts split snaps=0
  local c_std b_std c_sens b_sens
  local b_trash b_c4 b_c5 b_logs b_xcode b_dev
  local total_selected=0

  ui_clear_screen
  ui_out "${BLUE}── Simulação (s) — ganho em disco por etapa (0–9) ──${NC}"
  ui_out "  Mostra o ganho ${GREEN}se cada etapa for executada${NC}; [x] = marcada no menu."
  echo ""
  log "Calculando estimativas (resíduos podem demorar)…"
  echo ""

  b_trash=$(dir_size_bytes "$HOME/.Trash")
  c=$(count_immediate_children "$HOME/.Trash")
  menu_sim_row "1" "$STEP_TRASH" "Esvaziar Lixeira" "$c" "$b_trash"

  split=$(estimate_orphans_split)
  c_std=${split%% *}
  split=${split#* }
  b_std=${split%% *}
  split=${split#* }
  c_sens=${split%% *}
  b_sens=${split#* }
  menu_sim_row "2" "$STEP_ORPHANS" "Resíduos de apps" "$c_std" "$b_std" "estimativa"
  menu_sim_row "3" "$STEP_ORPHANS_SENSITIVE" "+ Preferences/Containers" "$c_sens" "$b_sens" "exige 2"

  stats=$(estimate_selective_caches_bytes)
  c=${stats%% *}
  b_c4=${stats#* }
  menu_sim_row "4" "$STEP_CACHES_FULL" "Caches ~/Library/Caches" "$c" "$b_c4"

  stats=$(estimate_safe_caches_bytes)
  c=${stats%% *}
  b_c5=${stats#* }
  menu_sim_row "5" "$STEP_CACHES_SAFE" "Caches seguros (dev/naveg.)" "$c" "$b_c5"

  stats=$(estimate_logs_bytes)
  c=${stats%% *}
  b_logs=${stats#* }
  menu_sim_row "6" "$STEP_LOGS" "Logs e crash reports" "$c" "$b_logs"

  stats=$(estimate_xcode_bytes)
  c=${stats%% *}
  b_xcode=${stats#* }
  menu_sim_row "7" "$STEP_XCODE" "Xcode / Simulador" "$c" "$b_xcode" "sem Archives"

  stats=$(estimate_devtools_bytes)
  parts=${stats%% *}
  b_dev=${stats#* }
  menu_sim_row "8" "$STEP_DEVTOOLS" "Homebrew, npm, pip…" "$parts" "$b_dev" "Docker à parte"

  if command -v tmutil >/dev/null 2>&1; then
    snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
  fi
  menu_sim_row "9" "$STEP_SYSTEM_SUDO" "Time Machine + fontes" "$snaps" "0" "sudo; tamanho TM n/d"

  menu_sim_row "0" "$STEP_MEMORY_PURGE" "purge — RAM" "—" "0" "sudo; não libera disco"

  if (( STEP_CACHES_FULL && STEP_CACHES_SAFE )); then
    echo ""
    ui_out "  ${YELLOW}!${NC} Opções 4 e 5 marcadas juntas — no total vale só uma (prioridade: 4)."
  fi
  if (( STEP_ORPHANS_SENSITIVE && ! STEP_ORPHANS )); then
    echo ""
    ui_out "  ${YELLOW}!${NC} Opção 3 marcada sem 2 — resíduos sensíveis não entram no total."
  fi

  total_selected=0
  (( STEP_TRASH )) && total_selected=$((total_selected + b_trash))
  (( STEP_ORPHANS )) && total_selected=$((total_selected + b_std))
  (( STEP_ORPHANS && STEP_ORPHANS_SENSITIVE )) && total_selected=$((total_selected + b_sens))
  if (( STEP_CACHES_FULL )); then
    total_selected=$((total_selected + b_c4))
  elif (( STEP_CACHES_SAFE )); then
    total_selected=$((total_selected + b_c5))
  fi
  (( STEP_LOGS )) && total_selected=$((total_selected + b_logs))
  (( STEP_XCODE )) && total_selected=$((total_selected + b_xcode))
  (( STEP_DEVTOOLS )) && total_selected=$((total_selected + b_dev))

  echo ""
  ui_out "$(printf "  ${GREEN}TOTAL se executar só o que está [x]:${NC}     ${BLUE}~%-9s${NC}" "$(human_size "$total_selected")")"
  echo ""
  printf '%b' "  Pressione Enter para voltar ao menu… "
  read -r _
  menu_flash "Simulação (s) concluída — use g para revisar e executar."
}

menu_gain_print_line() {
  local label=$1
  local count=$2
  local bytes=$3
  local note=${4:-}

  if [[ -n "$note" ]]; then
    ui_out "$(printf "  ${GREEN}•${NC} %-44s %5s itens  ${BLUE}~%-9s${NC}  (%s)" \
      "$label" "$count" "$(human_size "$bytes")" "$note")"
  else
    ui_out "$(printf "  ${GREEN}•${NC} %-44s %5s itens  ${BLUE}~%-9s${NC}" \
      "$label" "$count" "$(human_size "$bytes")")"
  fi
}

menu_compute_gain_estimate() {
  local total=0
  local stats c b parts

  echo ""
  log "Calculando estimativa (pode levar alguns segundos)…"
  ui_out "${BLUE}── Ganho estimado em disco ──${NC}"

  if (( STEP_TRASH )); then
    b=$(dir_size_bytes "$HOME/.Trash")
    c=$(count_immediate_children "$HOME/.Trash")
    menu_gain_print_line "Lixeira" "$c" "$b"
    total=$((total + b))
  fi

  if (( STEP_ORPHANS )); then
    stats=$(estimate_orphans_bytes)
    c=${stats%% *}
    b=${stats#* }
    menu_gain_print_line "Resíduos de apps" "$c" "$b" "estimativa"
    total=$((total + b))
  fi

  if (( STEP_CACHES_FULL )); then
    stats=$(estimate_selective_caches_bytes)
    c=${stats%% *}
    b=${stats#* }
    menu_gain_print_line "Caches do usuário" "$c" "$b"
    total=$((total + b))
  elif (( STEP_CACHES_SAFE )); then
    stats=$(estimate_safe_caches_bytes)
    c=${stats%% *}
    b=${stats#* }
    menu_gain_print_line "Caches seguros" "$c" "$b"
    total=$((total + b))
  fi

  if (( STEP_LOGS )); then
    stats=$(estimate_logs_bytes)
    c=${stats%% *}
    b=${stats#* }
    menu_gain_print_line "Logs e crash reports antigos" "$c" "$b"
    total=$((total + b))
  fi

  if (( STEP_XCODE )); then
    stats=$(estimate_xcode_bytes)
    c=${stats%% *}
    b=${stats#* }
    menu_gain_print_line "Xcode / Simulador / DeviceSupport" "$c" "$b" "sem Archives"
    total=$((total + b))
  fi

  if (( STEP_DEVTOOLS )); then
    stats=$(estimate_devtools_bytes)
    parts=${stats%% *}
    b=${stats#* }
    menu_gain_print_line "Ferramentas de dev (caches)" "$parts" "$b" "parcial; Docker à parte"
    total=$((total + b))
  fi

  if (( STEP_SYSTEM_SUDO )); then
    local snaps=0
    if command -v tmutil >/dev/null 2>&1; then
      snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
    fi
    menu_gain_print_line "Time Machine + fontes (sudo)" "$snaps" "0" "snapshots: tamanho não estimado"
  fi

  if (( STEP_MEMORY_PURGE )); then
    menu_gain_print_line "purge — RAM (sudo)" "—" "0" "não libera disco"
  fi

  echo ""
  ui_out "$(printf "  ${GREEN}TOTAL estimado (disco)${NC} %32s ${BLUE}~%-9s${NC}" "" "$(human_size "$total")")"
  echo ""
  MENU_EST_TOTAL=$total
}

menu_show_summary() {
  echo ""
  ui_out "${BLUE}── Resumo da seleção ──${NC}"
  menu_summary_line "$STEP_TRASH" "Lixeira"
  menu_summary_line "$STEP_ORPHANS" "Resíduos de apps"
  menu_summary_line "$STEP_ORPHANS_SENSITIVE" "Resíduos sensíveis (Preferences/Containers)"
  if (( STEP_CACHES_FULL )); then
    menu_summary_line 1 "Caches completos (~/Library/Caches)"
  elif (( STEP_CACHES_SAFE )); then
    menu_summary_line 1 "Caches seguros (dev/navegadores)"
  fi
  menu_summary_line "$STEP_LOGS" "Logs e crash reports antigos"
  menu_summary_line "$STEP_XCODE" "Xcode / Simulador / DeviceSupport"
  menu_summary_line "$STEP_DEVTOOLS" "Ferramentas de desenvolvimento"
  menu_summary_line "$STEP_SYSTEM_SUDO" "Time Machine local + cache de fontes (sudo)"
  menu_summary_line "$STEP_MEMORY_PURGE" "purge — RAM (sudo)"
  if (( DRY_RUN )); then
    echo ""
    warn "Dry-run: apenas inventário, sem apagar arquivos."
  fi
  if menu_has_risky_selection; then
    echo ""
    warn "Há etapas arriscadas ou com sudo — revise antes de confirmar."
  fi
  echo ""
}

menu_final_confirm() {
  local ans

  if ! menu_validate_selection; then
    return 1
  fi

  ui_clear_screen
  ui_out "${BLUE}── Revisão antes de executar ──${NC}"
  echo ""

  menu_show_summary
  menu_compute_gain_estimate

  if menu_has_risky_selection && (( ! DRY_RUN )); then
    ui_out "  ${RED}Etapas arriscadas.${NC} Digite ${GREEN}CONFIRMO${NC} para autorizar sudo/remoções."
    printf '%b' "  ou Enter vazio para voltar: "
    read -r ans
    if [[ "$ans" != "CONFIRMO" ]]; then
      menu_flash_warn "Confirmação arriscada cancelada."
      return 1
    fi
    MENU_RISKY_OK=1
  fi

  if (( DRY_RUN )); then
    printf '%b' "  Iniciar inventário? [S/n]: "
    read -r ans
    ans=$(printf '%s' "${ans:-S}" | tr '[:upper:]' '[:lower:]')
    if [[ "$ans" == "n" || "$ans" == "nao" || "$ans" == "não" ]]; then
      menu_flash_warn "Inventário dry-run cancelado."
      return 1
    fi
  else
    printf '%b' "  ${YELLOW}Executar limpeza agora? [s/N]:${NC} "
    read -r ans
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    if [[ "$ans" != "s" && "$ans" != "sim" && "$ans" != "y" && "$ans" != "yes" ]]; then
      menu_flash_warn "Limpeza não iniciada."
      return 1
    fi
  fi

  MENU_CONFIRMED=1
  return 0
}

interactive_menu() {
  local choice

  # Padrões sensatos na primeira visita
  STEP_TRASH=1
  STEP_CACHES_FULL=1
  STEP_LOGS=1

  while true; do
    menu_draw
    printf '%b' "  Opção: "
    read -r choice
    choice=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')

    case "$choice" in
      q|quit|sair)
        log "Saindo sem alterações."
        exit 0
        ;;
      g|go|executar)
        if menu_final_confirm; then
          ui_clear_screen
          break
        fi
        ;;
      s|sim|simular)
        menu_run_simulation
        ;;
      [0123456789]|p|a|d|y)
        menu_toggle "$choice" || menu_flash_warn "Atalho inválido: $choice"
        ;;
      *)
        menu_flash_warn "Use 0-9, p, a, d, y, s, g ou q."
        ;;
    esac
  done
}

apply_menu_to_runtime_flags() {
  CACHES_SAFE=$STEP_CACHES_SAFE
  SKIP_ORPHANS=$(( STEP_ORPHANS ? 0 : 1 ))
  CACHES_ONLY=$(( STEP_ORPHANS || STEP_XCODE || STEP_DEVTOOLS || STEP_SYSTEM_SUDO || STEP_MEMORY_PURGE ? 0 : 1 ))
  # CACHES_ONLY falso se qualquer etapa “extra” — usamos só STEP_* na pipeline
}

run_cleanup_pipeline() {
  local run_all=${1:-0}

  if (( run_all )); then
    empty_trash
    if (( ! SKIP_ORPHANS && ! CACHES_ONLY )); then
      purge_uninstalled_app_leftovers
    fi
    clear_user_caches
    if (( ! USER_CACHES_FULL && ! CACHES_SAFE )); then
      clear_dir_contents "Cache de ícones / QuickLook" "$HOME/Library/Caches/com.apple.iconservices.store"
    fi
    purge_old_logs
    if (( ! CACHES_ONLY )); then
      xcode_cleanup
      dev_tool_cleanup
      optional_system
      optional_memory_purge
    fi
    return 0
  fi

  if (( STEP_TRASH )); then
    empty_trash
  fi
  if (( STEP_ORPHANS )); then
    purge_uninstalled_app_leftovers
  fi
  if (( STEP_CACHES_FULL || STEP_CACHES_SAFE )); then
    CACHES_SAFE=$STEP_CACHES_SAFE
    clear_user_caches
    if (( STEP_CACHES_FULL && ! USER_CACHES_FULL )); then
      clear_dir_contents "Cache de ícones / QuickLook" "$HOME/Library/Caches/com.apple.iconservices.store"
    fi
  fi
  if (( STEP_LOGS )); then
    purge_old_logs
  fi
  if (( STEP_XCODE )); then
    xcode_cleanup
  fi
  if (( STEP_DEVTOOLS )); then
    dev_tool_cleanup
  fi
  if (( STEP_SYSTEM_SUDO )); then
    warn "Etapa opcional com sudo: snapshots locais do Time Machine e cache de fontes."
    if confirm_risky "Continuar com limpeza que pode pedir senha de administrador?"; then
      optional_system_body
    fi
  fi
  if (( STEP_MEMORY_PURGE )); then
    optional_memory_purge
  fi
}

main() {
  if [[ "$(uname -s)" != Darwin ]]; then
    err "Este script só funciona no macOS (Darwin)."
    exit 1
  fi

  local classic_mode=0

  while [[ $# -gt 0 ]]; do
    CLI_OPTS=1
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --dry-run-verbose) DRY_RUN=1; DRY_RUN_VERBOSE=1 ;;
      --yes) ASSUME_YES=1 ;;
      --yes-all|--full) YES_ALL=1; ASSUME_YES=1 ;;
      --caches-only) CACHES_ONLY=1 ;;
      --caches-safe) CACHES_SAFE=1 ;;
      --skip-orphans) SKIP_ORPHANS=1 ;;
      --orphans-include-sensitive) ORPHANS_SENSITIVE=1 ;;
      --menu) MENU_MODE=1 ;;
      --classic) classic_mode=1 ;;
      --help|-h) usage; exit 0 ;;
      *) err "Opção desconhecida: $1"; usage; exit 1 ;;
    esac
    shift
  done

  if (( ! CLI_OPTS && ! classic_mode )) && [[ -t 0 ]]; then
    MENU_MODE=1
  fi

  if (( MENU_MODE )); then
    interactive_menu
    apply_menu_to_runtime_flags
  fi

  if (( CACHES_SAFE && CACHES_ONLY )); then
    warn "--caches-safe com --caches-only: só lixeira, caches selecionados e logs."
  fi

  echo ""
  printf '%b\n' "${GREEN}=== Limpeza macOS ===${NC}"
  if (( DRY_RUN )); then
    if (( DRY_RUN_VERBOSE )); then
      warn "Modo dry-run detalhado — lista arquivos; nada será apagado"
    else
      warn "Dry-run — resumo e ganho estimado; nada será apagado"
    fi
  elif (( YES_ALL )); then
    warn "Modo --full: todas as etapas sem confirmação (resíduos, Docker agressivo, sudo, purge de RAM)"
  elif (( CACHES_ONLY )); then
    log "Modo --caches-only: sem resíduos de apps, Xcode, ferramentas de dev ou sudo"
  elif (( CACHES_SAFE )); then
    log "Modo --caches-safe: não esvazia ~/Library/Caches por completo"
  elif (( MENU_MODE )); then
    log "Executando etapas selecionadas no menu"
  fi
  echo ""

  local disk_before
  disk_before=$(df -k / | LC_ALL=C awk 'NR==2 { print $4 * 1024; exit }')
  log "Espaço livre no disco (volume /): $(human_size "$disk_before")"
  echo ""

  trap cleanup_temp_index EXIT INT TERM

  if (( MENU_MODE && DRY_RUN )); then
    FREED_BYTES=$MENU_EST_TOTAL
  else
    if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
      FREED_BYTES=0
      dry_run_print_banner
    fi

    if (( MENU_MODE )); then
      run_cleanup_pipeline 0
    else
      run_cleanup_pipeline 1
    fi

    if (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
      dry_run_print_total
    fi
  fi

  echo ""
  local disk_after
  disk_after=$(df -k / | LC_ALL=C awk 'NR==2 { print $4 * 1024; exit }')
  if (( MENU_MODE && DRY_RUN )); then
    ok "Dry-run: ~$(human_size "$MENU_EST_TOTAL") estimados — nada apagado."
  elif (( DRY_RUN && ! DRY_RUN_VERBOSE )); then
    : # total já exibido em dry_run_print_total
  else
    ok "Estimativa liberada nesta sessão (antes de re-scan do sistema): ~$(human_size "$FREED_BYTES")"
  fi
  log "Espaço livre agora (volume /): $(human_size "$disk_after")"
  echo ""
  warn "Reinicie apps abertos se algo ficar estranho; caches serão recriados automaticamente."
}

main "$@"
