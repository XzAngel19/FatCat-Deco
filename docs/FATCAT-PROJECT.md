# Fat Cat Project — estructura de módulos

La estructura que pediste, con esos nombres de carpeta y esos veinte archivos.
Este documento es el mapa: qué hace cada módulo, qué recibe, qué devuelve, y
por qué el árbol se ve así en disco.

## En disco

```
src/project/
├── FatCatSignal.lua            motor de eventos internos (pub/sub)
├── FatCatCore.lua              estado global, servicios, ciclo de vida/Unload
├── FatCatEnv.lua               el ejecutor: capacidades, identidad, Unload
├── FatCatConfig.lua            presets en disco (JSON)
├── FatCatDesign.lua            paletas, estilos, animaciones Tween
├── FatCatMaterials.lua         botones, toggles, sliders, temas
├── FatCatMenu.lua              contenedor principal y estructura visual
├── FatCatCreate.lua            creador/editor visual de GUIs
├── FatCatInspect.lua           inspector de instancias, propiedades, tablas
├── FatCatExtractor.lua         extracción de scripts del cliente
├── FatCatDecompiler.lua        front end del decompiler del ejecutor
├── FatCatStealer.lua           assets ya presentes en el cliente
├── FatCatSpy.lua               remote spy
├── FatCatProjectiles.lua       proyectiles: config, predicción, trayectoria
├── FatCatVMHook.lua            hooks de función y metamétodo
├── FatCatMemoryScanner.lua     búsqueda en el grafo de objetos
├── FatCatEnvSpoofer.lua        identidad reportada y sandbox
├── FatCatUniversal.lua         ESP, Fly, Noclip, Fullbright, teleport
├── FatCatMath.lua              vectores, W2S, predicción, trayectorias
└── FatCatConsole.lua           terminal flotante de logs y depuración
```

Y fuera de `src/project/`, porque no son módulos del árbol:

```
src/FatCatInit.lua           el bootstrapper (orden de carga, errores, Unload)
src/FatCatHub.lua            la ventana: shell, componentes, API
src/FatCatHub.bundle.lua     generado: los 21 archivos en un chunk
tools/build_bundle.py        el generador
```

## Por qué las carpetas no están en disco

Tu árbol agrupa los módulos en cinco carpetas con `&` y espacios
(`Core & Initialization/`, `UI & Styling Engine/`, …). En disco están todos
planos a propósito:

- **El loader baja un archivo, no un árbol.** Un ejecutor de Roblox recibe una
  URL y un string; no puede pedir `src/project/UI & Styling Engine/FatCatMenu.lua`
  en tiempo de ejecución. Todo lo que llegue al cliente tiene que estar dentro
  del bundle, y el bundle los concatena en un orden fijo.
- **Un `&` y un espacio en una ruta URL son una fuente de bugs** que no
  aportan nada: `%26`, `%20`, y un `HttpGet` que en algunos ejecutores no
  escapa. El nombre de carpeta no cambia el comportamiento del módulo.
- **El agrupamiento sigue existiendo** — en este documento y en el encabezado
  de cada archivo (`-- Fat Cat Project | Advanced Analysis/FatCatVictim`), que
  es donde un lector lo busca.

Si quieres las carpetas también en disco, se pueden crear como enlaces o
mover los archivos y ajustar `MODULES` en `tools/build_bundle.py`; el
generador acepta rutas en subcarpetas (`PROJECT.rglob`). Dímelo y lo hago.

## Los cinco grupos

### Core & Initialization

| Módulo | Qué hace | Recibe | Devuelve |
| --- | --- | --- | --- |
| `FatCatSignal` | pub/sub: `Connect`, `Once`, `Fire`, `Wait`, `Destroy` | — | tabla |
| `FatCatCore` | registro de servicios, caché de módulos, teardowns | — | tabla |
| `FatCatEnv` | detecta el ejecutor y sus capacidades; `unload()` | core, signal | tabla |
| `FatCatConfig` | presets JSON en `FatCatProject/presets/` | core, signal | tabla |
| `FatCatInit` | orden de carga, errores por etapa, tarjeta de error | tabla de módulos | tabla |

`FatCatCore` es el único global: `_G.FatCatProject`. Todo lo demás lo pide por
`Core:Require("FatCatSpy")`, nunca por una variable global suelta.

### UI & Styling Engine

| Módulo | Qué hace |
| --- | --- |
| `FatCatDesign` | paletas (`classic`, `ember`, `glacier`), escala tipográfica, curvas de Tween, contraste WCAG |
| `FatCatMaterials` | botones, toggles, sliders, dropdowns, inputs, código, status |
| `FatCatMenu` | las 7 pestañas sobre el shell; presets y tema |

`classic` es una copia exacta del `THEME` de `src/FatCatHub.lua`: las dos
mitades del producto tienen que abrir igual. Un componente que hardcodea un
`Color3` es un bug, porque deja de seguir la paleta y la auditoría no lo ve.

### Creation & Inspection Tools

| Módulo | Qué hace |
| --- | --- |
| `FatCatCreate` | documento (ids + `parent`), propiedades, `build()` a instancias reales |
| `FatCatInspect` | árbol con límite de nodos, propiedades, `format()` con ciclos |

El documento del creador es un array de nodos con `parent = id`, no un árbol de
tablas anidadas: así se serializa a JSON, se reordena y se borra sin copias
profundas. `Inspect.format` detecta ciclos y atrapa metatablas hostiles.

### Advanced Analysis, Exploitation & Anti-Tamper

| Módulo | Qué hace | Qué **no** hace |
| --- | --- | --- |
| `FatCatExtractor` | lista scripts, saca bytecode o decompilado, guarda | no inventa fuente que el cliente no tiene |
| `FatCatDecompiler` | llama al decompiler del ejecutor, numera líneas, guarda | no es un decompiler |
| `FatCatStealer` | ids de assets ya descargados, descarga públicos, manifiesto | no extrae mallas ni assets privados |
| `FatCatSpy` | envuelve `FireServer`/`OnClientEvent`, log con tipos | no bloquea, no modifica, no reenvía |
| `FatCatProjectiles` | config del proyectil, lead, arco, trail | no escribe en la tabla del juego |
| `FatCatVMHook` | hook de función/metamétodo con `Remove()` exacto | no hookea lo que no registró |
| `FatCatMemoryScanner` | busca strings/números en `getgc` e instancias | no es un lector de RAM del proceso |
| `FatCatEnvSpoofer` | cambia lo que responde `identifyexecutor`, sandbox | no evade anticheat (ver abajo) |

Sobre el "spoofer": cambiar `identifyexecutor` es cosmético. Nada en la ruta de
detección de un juego lo llama. Este módulo lo hace, y lo documenta como tal,
porque un spoofer que promete evasión se rompe al primer chequeo ternario y
vende una falsa sensación de seguridad. Lo que sí es real y reversible: el
sandbox de `getgenv()` para un script de la consola, y propiedades visuales de
instancias del cliente.

### Utilities, Console & Math

| Módulo | Qué hace |
| --- | --- |
| `FatCatMath` | `worldToScreen`, `predict` (forma cerrada), `arc`, `arcLanding`, ángulos |
| `FatCatUniversal` | ESP, fly, noclip, fullbright, teleport — todo reversible |
| `FatCatConsole` | log con filtro, runner Luau en sandbox, `Core` log sink |

`FatCatUniversal` guarda el valor original de walkspeed, salto, lighting y
cámara la primera vez que lo toca y lo devuelve en Unload. Un script que deja
al jugador a walkspeed 500 después de "descargarse" es peor que uno que nunca
corrió.

## El contrato de un módulo

Todo módulo del proyecto menos `FatCatSignal` y `FatCatCore` (que son tablas)
termina en:

```lua
return function(core, ...)
    -- captura las dependencias
    return Modulo
end
```

Reglas, y todas tienen un test que las cubre:

1. **Nada en el cuerpo del módulo toca `Core`.** El cuerpo corre cuando se
   *construye* el bundle; la fábrica corre cuando se *arranca*. Un
   `local env = Core.env` arriba del todo captura `nil` y el módulo explota al
   arrancar con "attempt to index nil". Hay un chequeo en `tools/validate.sh`
   que lo detecta (`bundle_spec.lua` arranca el bundle de verdad).
2. **Lo que se llama con `:` declara `self`.** `handle:Set(70)` con
   `Set = function(value)` recibe el número en `self` y `nil` en `value`; un
   setter numérico con guarda lo traga en silencio.
3. **Lo que asigna registra un teardown.** Conexión, `RenderStepped`, `Part` en
   `Camera`, `Highlight` en `CoreGui`: todo pasa por `Core:OnDestroy`.
4. **Un fallo no puede tumbar el menú.** `Mount` va por pestaña y en `pcall`;
   el error se escribe en la pestaña que falló.

## Verificación

```bash
python3 tools/build_bundle.py --check   # el bundle coincide con sus fuentes
bash tools/test_fatchub_bundle.sh       # 100 asserts sobre el proyecto ensamblado
node tools/luau/analyze.mjs --quiet src/FatCatInit.lua src/project/*.lua
```

El arnés del bundle arranca `FatCatInit` contra el DataModel simulado y
comprueba, entre otras cosas: que ningún módulo falló, que el shell publicó
`_G.FatCatHub`, que hay exactamente 7 pestañas y ninguna vacía, que un preset
llega al shell por su flag, y que `Core:Destroy()` deja `_G.FatCatProject` en
nil y no permite volver a pedir un módulo.
