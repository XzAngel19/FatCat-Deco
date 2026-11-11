# FatCat-Deco — Fat Cat Decompiler

Herramientas y banco de trabajo para leer, validar y volver a emitir código
Luau de Roblox (`Cobalt.txt`, un bundle runtime de 467 KB), más el shell del
menú **FatCat Hub**.

## Arranque

```bash
bash tools/luau/setup.sh --verify   # toolchain Luau desde los tarballs vendorizados
bash tools/validate.sh              # puerta completa del toolchain
bash tools/validate.sh --quick      # sin el type checker
bash tools/test_fatchub.sh          # 71 + 9 asserts sobre el menú (Roblox simulado)
bash tools/test_fatchub_loader.sh   # 51 asserts del loader, sin red
bash tools/render_fatchub.sh        # build/FatCatHub.png
```

Solo necesita `node` (v22) y `python3`. No hay `npm install` ni descargas: todo
está vendorizado en `tools/luau/vendor/`.

## FatCat Hub (menú vacío)

```
src/FatCatHub.lua          el menú: shell, componentes, API
src/FatCatHub.project.lua  lo que el juego rellena (vacío por ahora)
src/FatCatHub.loader.lua   loader de una línea
docs/FATCAT-HUB.md         API, componentes y lista de bugs corregidos
```

```lua
-- main todavía no tiene src/, así que hoy el loader vive en la rama de trabajo
loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/arena/4918f801-fatcat-deco/src/FatCatHub.loader.lua"))()
```

Una vez cargado, el loader resuelve solo de qué rama bajar la librería (prueba
`main` y luego la rama de trabajo). Se cierra con `getgenv().FatCatHubUnload()`.

## Herramientas

| Comando | Qué hace |
| --- | --- |
| `tools/luau/bin/luau <file>` | ejecuta Luau (harnesses) |
| `tools/luau/bin/luau-compile <file…>` | comprueba sintaxis |
| `tools/luau/bin/luau-analyze <file…>` | type check + lints contra el API de Roblox y el executor |
| `tools/luau/bin/luau-format <file…>` | StyLua |
| `tools/luau/bin/luau-minify <file> -o out` | DarkLua |
| `tools/luau/bin/luau-disasm <file>` | prototipos, opcodes y constantes del bytecode |
| `tools/luau/bin/luau-validate <file>` | integridad del contenedor `.luauc` |

`bash tools/luau/setup.sh` recrea los binarios desde los tarballs.

```bash
tools/luau/bin/luau-disasm Cobalt.txt --stats     # 610 prototipos, 26 761 instrucciones
tools/luau/bin/luau-validate Cobalt.txt           # 1 713 strings de header, 398 976 bytes
node tools/luau/analyze.mjs --baseline            # 0 errores nuevos
```

## Documentación

- [`docs/FATCAT-HUB.md`](docs/FATCAT-HUB.md) — el menú: API, componentes, bugs.
- [`docs/LUAU-TOOLCHAIN.md`](docs/LUAU-TOOLCHAIN.md) — qué se instaló y por qué.
- `AGENTS.md` — guía de trabajo del repositorio.
