# FatCat-Deco — Fat Cat Decompiler

Herramientas y banco de trabajo para leer, validar y volver a emitir código
Luau de Roblox (`Cobalt.txt`, un bundle runtime de 467 KB), más el shell del
menú **Fat Cat**.

## Arranque

```bash
bash tools/luau/setup.sh --verify   # toolchain Luau desde los tarballs vendorizados
bash tools/validate.sh              # puerta completa del toolchain
bash tools/validate.sh --quick      # sin el type checker
bash tools/test_fatchub.sh          # 94 + 16 asserts sobre el menú (Roblox simulado)
bash tools/test_fatchub_loader.sh   # 51 asserts del loader, sin red
bash tools/test_fatchub_bundle.sh   # 100 asserts sobre el proyecto ensamblado
python3 tools/build_bundle.py       # regenera src/FatCatHub.bundle.lua
bash tools/design.sh                # render + auditoría: build/FatCatHub.png
bash tools/design.sh --project      # las pestañas del decompiler
```

Solo necesita `node` (v22) y `python3`. No hay `npm install` ni descargas: todo
está vendorizado en `tools/luau/vendor/`.

## Fat Cat (menú del decompiler)

```
src/FatCatHub.lua          el menú: shell, componentes, API
src/FatCatHub.project.lua  las ventanas: Decompiler, Executor, Hooks
src/FatCatHub.loader.lua   loader de una línea
docs/FATCAT-HUB.md         API, componentes y lista de bugs corregidos
```

```lua
-- main todavía no tiene src/, así que hoy el loader vive en la rama de trabajo
loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/arena/292e8b51-fatcat-deco/src/FatCatHub.loader.lua"))()
```

El loader descarga **`src/FatCatHub.bundle.lua`** (los 21 módulos del proyecto
más el bootstrapper, generados) y resuelve solo de qué rama bajarlo: prueba
`main` y luego las ramas de trabajo. Se cierra con
`getgenv().FatCatProjectUnload()`, que restaura walkspeed, salto, ESP y hooks.

### Estructura del proyecto

Los módulos viven en `src/project/` y cada uno es un archivo independiente que
se puede leer solo. `tools/build_bundle.py` los concatena en un único chunk.

```
src/FatCatInit.lua            arranque, orden de carga, control de errores
src/FatCatHub.bundle.lua      generado: no editar
src/project/
  FatCatSignal.lua            eventos internos (pub/sub)
  FatCatCore.lua              estado global, servicios, Unload
  FatCatEnv.lua               ejecutor: detección de capacidades, Unload
  FatCatConfig.lua            presets en disco (JSON)
  FatCatDesign.lua            paletas, tipografía, curvas de animación
  FatCatMaterials.lua         botones, toggles, sliders, dropdowns, código
  FatCatMenu.lua              las 7 pestañas sobre el shell
  FatCatCreate.lua            creador/editor visual de GUIs
  FatCatInspect.lua           jerarquías, propiedades, tablas
  FatCatExtractor.lua         extracción de scripts (bytecode/decompilado)
  FatCatDecompiler.lua        front end del decompiler del ejecutor
  FatCatStealer.lua           assets ya presentes en el cliente
  FatCatSpy.lua               remote spy (FireServer/OnClientEvent)
  FatCatProjectiles.lua       config de proyectiles y trayectorias
  FatCatVMHook.lua            hooks de función y metamétodo, reversibles
  FatCatMemoryScanner.lua     búsqueda en el grafo de objetos (gc/instancias)
  FatCatEnvSpoofer.lua        identidad de identifyexecutor, sandbox
  FatCatUniversal.lua         ESP, fly, noclip, fullbright, teleport
  FatCatMath.lua              vectores, W2S, predicción, trayectorias
  FatCatConsole.lua           terminal flotante de logs + runner Luau
```

La ventana sigue siendo `src/FatCatHub.lua`: es el shell que ya cubren los 94
asserts y el que la auditoría de diseño mide. `FatCatMenu` monta las pestañas
del proyecto encima, no lo reescribe.

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
| `bash tools/design.sh` | volcado + PNG con texto real + auditoría de diseño |
| `python3 tools/fatchub/audit.py build/layout.txt` | informe de recortes, contraste, targets |

`bash tools/luau/setup.sh` recrea los binarios desde los tarballs.

```bash
tools/luau/bin/luau-disasm Cobalt.txt --stats     # 610 prototipos, 26 761 instrucciones
tools/luau/bin/luau-validate Cobalt.txt           # 1 713 strings de header, 398 976 bytes
node tools/luau/analyze.mjs --baseline            # 0 errores nuevos
```

## Documentación

- [`docs/FATCAT-HUB.md`](docs/FATCAT-HUB.md) — el menú: API, componentes, bugs.
- [`docs/FATCAT-PROJECT.md`](docs/FATCAT-PROJECT.md) — los 20 módulos del proyecto y su contrato.
- [`docs/FATCAT-DESIGN.md`](docs/FATCAT-DESIGN.md) — render con letras reales y auditoría de diseño.
- [`docs/LUAU-TOOLCHAIN.md`](docs/LUAU-TOOLCHAIN.md) — qué se instaló y por qué.
- `AGENTS.md` — guía de trabajo del repositorio.
