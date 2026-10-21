#!/usr/bin/env bash
# Limpeza segura para macOS — alternativa leve ao CleanMyMac.
# Uso: ./cleanup-mac.sh [--dry-run] [--yes] [--yes-all|--full] [--help]

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
YES_ALL=0
FREED_BYTES=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<'EOF'
cleanup-mac.sh — limpeza de caches e arquivos temporários (macOS)

Opções:
  --dry-run       Inventário completo do que seria limpo (sem apagar, sem perguntas)
  --yes           Aceita etapas seguras sem perguntar (arriscadas ainda pedem)
  --yes-all       Aceita tudo sem perguntar (inclui resíduos, sudo, Docker agressivo)
  --full          Alias de --yes-all
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

log()  { printf "${BLUE}[*]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; }

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
  if (( ASSUME_YES || DRY_RUN )); then
    return 0
  fi
  read -r -p "$(printf "${YELLOW}%s [s/N]:${NC} " "$prompt")" ans
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  [[ "$ans" == "s" || "$ans" == "sim" || "$ans" == "y" || "$ans" == "yes" ]]
}

# Etapas destrutivas ou com sudo — nunca puladas com --yes
confirm_risky() {
  local prompt=$1
  if (( DRY_RUN )); then
    warn "(dry-run) Etapa arriscada incluída no inventário: $prompt"
    return 0
  fi
  if (( YES_ALL )); then
    return 0
  fi
  read -r -p "$(printf "${RED}%s [s/N]:${NC} " "$prompt")" ans
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  [[ "$ans" == "s" || "$ans" == "sim" || "$ans" == "y" || "$ans" == "yes" ]]
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

  log "${label} — ${count} item(ns), ~$(human_size "$total") em ${dir}"
  while IFS=$'\t' read -r size entry; do
    printf '  - %s  %s\n' "$(human_size "$size")" "$entry"
  done < <(sort -nr "$tmp")
  rm -f "$tmp"
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
    dry_run_list_path_entries "$label (seria removido)" "$dir"
    FREED_BYTES=$((FREED_BYTES + before))
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
    dry_run_list_path_entries "Lixeira (seria esvaziada)" "$trash"
    FREED_BYTES=$((FREED_BYTES + before))
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
  local app_roots="/Applications /System/Applications ${HOME}/Applications"

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
  done < <(find $app_roots -maxdepth 4 -name '*.app' 2>/dev/null)

  sort -fu "$INSTALLED_BUNDLE_IDS" -o "$INSTALLED_BUNDLE_IDS"
  sort -fu "$INSTALLED_APP_NAMES" | LC_ALL=C awk '{ print tolower($0) }' | sort -fu -o "$INSTALLED_APP_NAMES"
}

leftover_name_whitelisted() {
  local key=$1
  local lower
  lower=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    shared|clouddocs|icloud|apple|android|network|syncservices|mobilesync|callhistorydb|\
    knowledge|homekit|messages|mail|contacts|calendar|loginwindow|dock|finder|system)
      return 0
      ;;
  esac

  [[ "$key" == com.apple.* ]] && return 0
  [[ "$key" == group.com.apple.* ]] && return 0
  [[ "$key" == *".apple."* ]] && return 0
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
  [[ -e "$path" ]] || return 0
  size=$(dir_size_bytes "$path")
  (( size == 0 )) && return 0
  printf '%s\t%s\n' "$size" "$path" >>"$ORPHAN_CANDIDATES"
}

collect_broken_app_bundles() {
  local app_roots="/Applications ${HOME}/Applications"
  local app

  while IFS= read -r app; do
    [[ -f "$app/Contents/Info.plist" ]] && continue
    append_orphan_candidate "$app"
  done < <(find $app_roots -maxdepth 4 -name '*.app' 2>/dev/null)
}

collect_library_leftovers() {
  local lib_dir entry base

  local scan_roots=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Containers"
    "$HOME/Library/Group Containers"
    "$HOME/Library/HTTPStorages"
    "$HOME/Library/Logs"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/WebKit"
    "$HOME/Library/Preferences"
    "$HOME/Library/PreferencePanes"
    "$HOME/Library/Internet Plug-Ins"
    "$HOME/Library/Services"
    "$HOME/Library/Application Support/CrashReporter"
  )

  for lib_dir in "${scan_roots[@]}"; do
    [[ -d "$lib_dir" ]] || continue
    while IFS= read -r entry; do
      base=$(basename "$entry")
      [[ "$base" == .DS_Store ]] && continue
      leftover_entry_matches_installed "$base" && continue
      append_orphan_candidate "$entry"
    done < <(find "$lib_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type f -o -type l \) 2>/dev/null)
  done
}

purge_uninstalled_app_leftovers() {
  local ORPHAN_CANDIDATES=""
  local total_bytes=0
  local count=0
  local line path size
  local preview_limit=40
  if (( DRY_RUN )); then
    preview_limit=999999
  fi

  ORPHAN_CANDIDATES="${CLEANUP_MAC_TMPDIR:-${TMPDIR:-/tmp}}/orphans.$$"
  : >"$ORPHAN_CANDIDATES"

  build_installed_app_index
  collect_broken_app_bundles
  collect_library_leftovers

  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    total_bytes=$((total_bytes + size))
    count=$((count + 1))
  done <"$ORPHAN_CANDIDATES"

  if (( count == 0 )); then
    ok "Nenhum resíduo óbvio de app desinstalado encontrado"
    cleanup_temp_index
    rm -f "$ORPHAN_CANDIDATES"
    return 0
  fi

  log "Resíduos de apps desinstalados — ${count} item(ns), ~$(human_size "$total_bytes")"
  if (( ! DRY_RUN )); then
    warn "Revise a lista: pastas genéricas (ex.: Google, Adobe) podem ser de apps ainda em uso."
  fi

  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    printf '  - %s  %s\n' "$(human_size "$size")" "$path"
  done < <(sort -nr "$ORPHAN_CANDIDATES" | head -n "$preview_limit")
  if (( count > preview_limit )); then
    printf '  ... e mais %s item(ns)\n' "$((count - preview_limit))"
  fi

  if (( DRY_RUN )); then
    FREED_BYTES=$((FREED_BYTES + total_bytes))
    cleanup_temp_index
    rm -f "$ORPHAN_CANDIDATES"
    return 0
  fi

  if ! confirm_risky "Remover estes resíduos de apps desinstalados?"; then
    warn "Pulado: resíduos de apps"
    cleanup_temp_index
    rm -f "$ORPHAN_CANDIDATES"
    return 0
  fi

  while IFS=$'\t' read -r size path; do
    [[ -z "$path" ]] && continue
    if (( DRY_RUN )); then
      ok "(dry-run) Removeria resíduo: $path (~$(human_size "$size"))"
    else
      rm -rf "$path" 2>/dev/null || true
      ok "Resíduo removido: $path (~$(human_size "$size"))"
    fi
    FREED_BYTES=$((FREED_BYTES + size))
  done < <(sort -nr "$ORPHAN_CANDIDATES")
  ok "Resíduos processados: ${count} item(ns), ~$(human_size "$total_bytes")"
  cleanup_temp_index
  rm -f "$ORPHAN_CANDIDATES"
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
    if (( count == 0 )); then
      ok "Nenhum log com mais de ${days} dias para remover"
      rm -f "$tmp"
      return 0
    fi
    log "Logs (> ${days} dias) — ${count} arquivo(s), ~$(human_size "$total")"
    while IFS=$'\t' read -r size path; do
      printf '  - %s  %s\n' "$(human_size "$size")" "$path"
    done < <(sort -nr "$tmp")
    FREED_BYTES=$((FREED_BYTES + total))
    rm -f "$tmp"
    return 0
  fi

  log "Logs do usuário (> ${days} dias) — pasta total ~$(human_size "$before")"
  if ! confirm "Remover arquivos de log com mais de ${days} dias?"; then
    warn "Pulado: logs antigos"
    return 0
  fi

  find "$log_dir" -type f -mtime +"$days" -delete 2>/dev/null || true
  ok "Logs antigos removidos"
}

dev_tool_cleanup() {
  if command -v brew >/dev/null 2>&1; then
    local brew_cache
    brew_cache=$(dir_size_bytes "$(brew --cache 2>/dev/null || echo "")")
    log "Homebrew — cache ~$(human_size "$brew_cache")"
    if confirm "Rodar brew cleanup (remove caches e versões antigas)?"; then
      if (( DRY_RUN )); then
        log "Homebrew — simulação (brew cleanup -n):"
        brew cleanup -n 2>/dev/null | sed 's/^/  /' || ok "(dry-run) brew cleanup -s && brew autoremove"
      else
        brew cleanup -s 2>/dev/null || true
        brew autoremove 2>/dev/null || true
        ok "Homebrew cleanup concluído"
      fi
    fi
  fi

  if command -v npm >/dev/null 2>&1; then
    if confirm "Limpar cache do npm?"; then
      if (( DRY_RUN )); then
        log "npm cache — $(npm config get cache 2>/dev/null || echo '?')"
        dry_run_list_path_entries "npm cache (seria limpo)" "$(npm config get cache 2>/dev/null || echo "$HOME/.npm")"
      else
        run_cmd "npm cache" npm cache clean --force
      fi
    fi
  fi

  if command -v yarn >/dev/null 2>&1; then
    if confirm "Limpar cache do Yarn?"; then
      if (( DRY_RUN )); then
        log "Yarn cache — $(yarn cache dir 2>/dev/null || echo '?')"
        dry_run_list_path_entries "Yarn cache (seria limpo)" "$(yarn cache dir 2>/dev/null || echo "$HOME/Library/Caches/Yarn")"
      else
        run_cmd "Yarn cache" yarn cache clean
      fi
    fi
  fi

  if command -v pip3 >/dev/null 2>&1; then
    if confirm "Limpar cache do pip?"; then
      if (( DRY_RUN )); then
        local pip_cache
        pip_cache=$(pip3 cache dir 2>/dev/null || echo "$HOME/Library/Caches/pip")
        log "pip cache — $pip_cache"
        dry_run_list_path_entries "pip cache (seria limpo)" "$pip_cache"
      else
        run_cmd "pip cache" pip3 cache purge
      fi
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    warn "Docker: remove imagens/containers/volumes NÃO usados (pode ser grande)."
    if confirm "Rodar docker system prune -f (sem volumes)?"; then
      if (( DRY_RUN )); then
        log "Docker — espaço recuperável (docker system df):"
        docker system df -v 2>/dev/null | sed 's/^/  /' || true
        ok "(dry-run) Executaria: docker system prune -f"
      else
        run_cmd "Docker prune" docker system prune -f
      fi
    fi
    if confirm_risky "Rodar docker system prune -af (TODAS imagens não usadas)?"; then
      run_cmd "Docker prune agressivo" docker system prune -af
    fi
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
}

optional_system() {
  warn "Etapa opcional com sudo: snapshots locais do Time Machine e cache de fontes."
  if ! confirm_risky "Continuar com limpeza que pode pedir senha de administrador?"; then
    return 0
  fi

  if command -v tmutil >/dev/null 2>&1; then
    local snaps
    snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
    if (( snaps > 0 )); then
      log "Encontrados $snaps snapshot(s) local(is) do Time Machine"
      if confirm_risky "Remover snapshots locais (libera espaço no disco de boot)?"; then
        if (( DRY_RUN )); then
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
    if (( DRY_RUN )); then
      ok "(dry-run) atsutil databases -remove"
    else
      sudo atsutil databases -remove 2>/dev/null || true
      ok "Cache de fontes limpo"
    fi
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --yes-all|--full) YES_ALL=1; ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) err "Opção desconhecida: $1"; usage; exit 1 ;;
    esac
    shift
  done

  echo ""
  printf "${GREEN}=== Limpeza macOS ===${NC}\n"
  if (( DRY_RUN )); then
    warn "Modo dry-run: inventário completo — nada será apagado, nenhuma pergunta"
  elif (( YES_ALL )); then
    warn "Modo --full: todas as etapas serão executadas sem confirmação (inclui sudo e remoções arriscadas)"
  fi
  echo ""

  local disk_before
  disk_before=$(df -k / | LC_ALL=C awk 'NR==2 { print $4 * 1024; exit }')
  log "Espaço livre no disco (volume /): $(human_size "$disk_before")"
  echo ""

  trap cleanup_temp_index EXIT

  empty_trash
  purge_uninstalled_app_leftovers
  clear_dir_contents "Caches do usuário" "$HOME/Library/Caches"
  clear_dir_contents "Cache de ícones / QuickLook" "$HOME/Library/Caches/com.apple.iconservices.store"
  purge_old_logs
  xcode_cleanup
  dev_tool_cleanup
  optional_system

  echo ""
  local disk_after
  disk_after=$(df -k / | LC_ALL=C awk 'NR==2 { print $4 * 1024; exit }')
  ok "Estimativa liberada nesta sessão (antes de re-scan do sistema): ~$(human_size "$FREED_BYTES")"
  log "Espaço livre agora (volume /): $(human_size "$disk_after")"
  echo ""
  warn "Reinicie apps abertos se algo ficar estranho; caches serão recriados automaticamente."
}

main "$@"
