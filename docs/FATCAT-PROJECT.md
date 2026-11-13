# Fat Cat Project — estructura de módulos

La estructura que pediste, con esos nombres de carpeta y esos veinte archivos*.
Este documento es el mapa: qué hace cada módulo, qué recibe, qué devuelve, y
cómo se ensambla en un solo chunk.

\* veintiuno con `FatCatInit`, que es el bootstrapper y no un módulo de
servicio: vive en `Core & Initialization/` porque ahí es donde se busca.

## En disco

Las cinco carpetas son literales, con el `&` y los espacios del nombre:

```
src/project/
├── Core & Initialization/
│   ├── FatCatSignal.lua        motor de eventos internos (pub/sub)
│   ├── FatCatCore.lua          estado global, servicios, ciclo de vida/Unload
│   ├── FatCatEnv.lua           el ejecutor: capacidades, identidad, Unload
│   ├── FatCatConfig.lua        presets en disco (JSON)
│   └── FatCatInit.lua          el bootstrapper: orden de carga, errores, Unload
├── UI & Styling Engine/
│   ├── FatCatDesign.lua        paletas, estilos, animaciones Tween
│   ├── FatCatMaterials.lua     botones, toggles, sliders, temas
│   └── FatCatMenu.lua          contenedor principal y estructura visual
├── Creation & Inspection Tools/
│   ├── FatCatCreate.lua        creador/editor visual de GUIs
│   └── FatCatInspect.lua       inspector de instancias, propiedades, tablas
├── Advanced Analysis, Exploitation & Anti-Tamper/
│   ├── FatCatExtractor.lua     extracción de scripts del cliente
│   ├── FatCatDecompiler.lua    front end del decompiler del ejecutor
│   ├── FatCatStealer.lua       assets ya presentes en el cliente
│   ├── FatCatSpy.lua           remote spy
│   ├── FatCatProjectiles.lua   proyectiles: config, predicción, trayectoria
│   ├── FatCatVMHook.lua        hooks de función y metamétodo
│   ├── FatCatMemoryScanner.lua búsqueda en el grafo de objetos
│   └── FatCatEnvSpoofer.lua    identidad reportada y sandbox
└── Utilities, Console & Math/
    ├── FatCatMath.lua          vectores, W2S, predicción, trayectorias
    ├── FatCatUniversal.lua     ESP, Fly, Noclip, Fullbright, teleport
    └── FatCatConsole.lua       terminal flotante de logs y depuración
```

Y fuera de `src/project/`, porque no son módulos del árbol:

```
src/FatCatHub.lua            la ventana: shell, componentes, API
src/FatCatHub.bundle.lua     generado: los 21 archivos en un chunk
src/FatCatHub.loader.lua     el que descarga y arranca el bundle
tools/build_bundle.py        el generador
```

## La carpeta es documentación, no despacho

`require` toma nombres pelados (`Core:Require("FatCatSpy")`), nunca una ruta
con carpeta ni una barra. Eso no es una limitación que haya que rodear: el
bundle es plano y busca por nombre, así que la carpeta solo dice **de qué
grupo es un archivo** y dónde editarlo.

En consecuencia:

- **El loader baja un archivo, no un árbol.** Un ejecutor de Roblox recibe una
  URL y un string; no puede pedir `src/project/UI & Styling Engine/FatCatMenu.lua`
  en tiempo de ejecución. Todo lo que llega al cliente está dentro del bundle.
- **Las rutas con `&` y espacios no van a una URL.** Por eso
  `src/FatCatHub.bundle.lua` es la única ruta que se descarga; las carpetas
  existen en el repositorio, donde un `git clone` las maneja bien.
- **`tools/build_bundle.py` busca recursivamente** (`PROJECT.rglob`), así que
  mover un módulo de carpeta no requiere tocar el generador. Sí requiere que
  el nombre sea único: dos `FatCatMath.lua` en grupos distintos son un error de
  build, no una precedencia silenciosa.
- **El orden de carga no depende de la carpeta.** Está en `MODULES` dentro de
  `tools/build_bundle.py` y en `FatCatInit`: primero señales, después el core,
  después lo que necesita un core.

El chequeo de estructura vive en `tools/test_fatchub_bundle.sh`: verifica que
las cinco carpetas existan con el nombre literal, que cada módulo esté en la
suya, y que no haya módulos sueltos en `src/project/`. Renombrar una carpeta
rompe la puerta, no el producto.

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

## Qué pasa si un módulo falla

El arranque está dividido por etapas y no todas son fatales. La regla es simple:
**lo que hace falta para abrir una ventana es fatal; lo que solo mejora la
ventana no lo es.**

| Etapa | Si falla |
| --- | --- |
| `FatCatSignal`, `FatCatCore`, `FatCatEnv` | fatal: sin ellos no hay proyecto |
| `FatCatConfig`, `FatCatDesign`, `FatCatMaterials`, `FatCatMath` | se registra el fallo, se sigue sin ese módulo |
| `FatCatShell` | fatal: no hay dónde dibujar |
| `FatCatMenu` | se reintenta una vez sin las pestañas de módulo (`build{ plain = true }`) |
| cualquier otro módulo | perezoso: se carga al pedirlo, y `TryRequire` devuelve `nil` con el motivo |

Un fallo no es silencioso: entra en `Init.booted.failures`, se escribe con
`Core:Log("warn", ...)` y queda en el reporte que imprime el loader. Lo que se
evita es que **tumbe el menú**, no que se sepa.

Eso se comprueba de verdad, no de palabra: `tools/test_fatchub_bundle.sh`
genera un segundo chunk en el que el factory de `FatCatMaterials` lanza a
propósito, y exige que el boot llegue a `ready`, que el shell publique la
ventana, que `Home` exista y que el fallo esté nombrado en el reporte. Con la
política anterior ese mismo chunk fallaba en cinco asserts y no había ni shell.

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
python3 tools/lint_module_body.py       # ningún cuerpo lee una dependencia
bash tools/test_fatchub_bundle.sh       # 137 asserts + la forma del árbol
bash tools/test_fatchub_loader.sh       # 57 asserts del loader, con el bundle real
node tools/luau/analyze.mjs --quiet "src/project"
```

`tools/lint_module_body.py` cubre un hueco que el type checker no puede ver: un
nombre declarado y todavía sin asignar es `nil` en tiempo de ejecución, no un
error de análisis. El lint distingue las tres cosas que se parecen en el cuerpo
de un módulo — declarar (`local Core, Design`), construir lo propio
(`Menu = {}`) y **leer una dependencia** (`local x = Core.env.foo`) — y solo la
tercera es un fallo. Se salta los cuerpos de función a propósito: esos corren
después de la fábrica.

El arnés del loader no prueba un cuerpo inventado: `tools/test_fatchub_loader.sh`
incrusta `src/FatCatHub.bundle.lua` tal como está en disco y se lo sirve al
loader, así que un bundle que ya no cargue falla ahí y no en el ejecutor.

El arnés del bundle arranca `FatCatInit` contra el DataModel simulado y
comprueba, entre otras cosas: que ningún módulo falló, que el shell publicó
`_G.FatCatHub`, que hay exactamente 7 pestañas y ninguna vacía, que un preset
llega al shell por su flag, y que `Core:Destroy()` deja `_G.FatCatProject` en
nil y no permite volver a pedir un módulo.
