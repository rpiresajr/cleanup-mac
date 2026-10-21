# Limpeza macOS (`cleanup-mac.sh`)

Script em bash para liberar espaço no Mac sem ferramentas pagas. Foca em **caches**, **lixeira**, **resíduos de apps desinstalados**, **logs antigos** e **ferramentas de desenvolvimento** (Homebrew, npm, Docker, Xcode).

## Resíduos de apps desinstalados

Compara o que está em `/Applications`, `~/Applications` e `/System/Applications` com pastas/arquivos em `~/Library` (Application Support, Preferences, Containers, logs, etc.). Itens sem app correspondente aparecem na lista antes de apagar.

- `.app` quebrados em `/Applications` (sem `Info.plist`) também entram na lista
- Etapa **arriscada**: sempre pede confirmação (`--yes` não pula)
- Pastas genéricas do sistema (Apple, Shared, Mail, etc.) são ignoradas

## O que **não** faz (de propósito)

- Não remove apps instalados, documentos ou fotos (só resíduos em `~/Library` sem `.app` correspondente)
- Não mexe em `/System` sem você confirmar etapas com `sudo`
- Não apaga cookies/senhas do Safari ou Keychain

## Limpar `~/Library/Caches` — o que acontece?

O script remove **só o conteúdo** dessa pasta (a pasta `Caches` continua existindo). Cada subpasta costuma ser de um app ou do sistema (ex.: `com.google.Chrome`, `Homebrew`, `npm`).

| Efeito | Detalhe |
|--------|---------|
| **Seguro em geral** | Não apaga documentos, fotos, preferências (`~/Library/Preferences`) nem dados de login (Keychain). |
| **Espaço em disco** | Libera bastante espaço; é o alvo principal desta etapa. |
| **Primeira abertura dos apps** | Pode ficar um pouco mais lenta enquanto o app recria cache (imagens, miniaturas, dados temporários). |
| **Navegador** | Sites podem carregar de novo do zero (sem cache local); você **não** perde senhas salvas no navegador por causa disso. |
| **Apps offline** | Apps que guardam conteúdo *só* em cache (ex.: música/podcast offline) podem precisar baixar de novo — raro, mas possível. |
| **Ícones / Finder** | Ícones ou miniaturas podem piscar ou regenerar; normal. |

Ou seja: equivalente a “limpar cache” manualmente — incomoda no máximo na primeira utilização depois da limpeza.

## Uso

```bash
cd ~/Documents/PROJECTS/cleanup-mac
chmod +x cleanup-mac.sh

# Inventário completo (lista cada pasta/arquivo candidato, sem apagar):
./cleanup-mac.sh --dry-run

# Interativo (recomendado na primeira vez):
./cleanup-mac.sh

# Etapas seguras sem perguntar (resíduos de apps, sudo e Docker agressivo ainda pedem):
./cleanup-mac.sh --yes

# Tudo sem perguntar (vai pedir senha de admin só onde o macOS exigir sudo):
./cleanup-mac.sh --full
# ou: ./cleanup-mac.sh --yes-all
```

## Atalho no terminal

```bash
mkdir -p ~/bin
ln -sf ~/cleanup-mac/cleanup-mac.sh ~/bin/cleanup-mac
```

Garanta que `~/bin` está no `PATH` (no `~/.zshrc`):

```bash
export PATH="$HOME/bin:$PATH"
```

Depois: `cleanup-mac --dry-run`

## Agendamento (opcional)

Limpeza leve semanal (só caches + lixeira, com confirmação `--yes` nas partes seguras):

```bash
crontab -e
```

Exemplo (domingo 3h — ajuste o caminho):

```
0 3 * * 0 /Users/renatoaraujo/Documents/PROJECTS/cleanup-mac/cleanup-mac.sh --yes >> /tmp/cleanup-mac.log 2>&1
```

Para automação total, prefira rodar manualmente ou usar `--dry-run` antes de mudar o cron.

## Dicas extras (manual)

- **Armazenamento**: Ajustes do Sistema → Geral → Armazenamento
- **Downloads antigos**: revise `~/Downloads` manualmente
- **Mail**: caixa com anexos grandes no app Mail
- **Parallels/VMs**: discos virtuais costumam ocupar muito espaço
